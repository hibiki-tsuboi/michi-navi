import CarPlay
import MapKit

/// CarPlay の `CPWindow` に敷く地図。
///
/// テンプレート（上部バー・案内カード・下部ボタン）は地図の上に重なって描かれる。
/// そのぶんは `view.safeAreaInsets` に入ってくるので、中心合わせや全体表示では
/// 必ずこれを差し引く。差し引かないと自車位置が案内カードの裏に隠れる。
final class CarPlayMapViewController: UIViewController {
    enum Style {
        /// センターディスプレイ。目的地ピンとズーム操作を伴う。
        case full
        /// ダッシュボード。狭いので余計なものを描かない（ガイド p.54）。
        case compact
        /// メーター内。狭さは `.compact` と同じだが、**進行方向を上に固定する**のが
        /// ガイド p.55 の要件なので、こちらだけ向きの設定に従わない。
        case cluster

        /// 目的地ピンや太い線を出してよい広さがあるか。
        var isWide: Bool { self == .full }
    }

    private let style: Style
    private let mapView = MKMapView()
    private var routeOverlay: MKPolyline?
    /// 経由地と目的地のピン。広い画面でだけ出す。
    private var routeAnnotations: [MKPointAnnotation] = []

    /// 自車を追従する（案内中）か、地図を自由に見せる（パン中・全体表示中）か。
    private(set) var isFollowingUser = true

    /// 追従時のカメラ高度。ズームボタンとピンチで上下する。
    private var cameraDistance: CLLocationDistance
    private let minimumCameraDistance: CLLocationDistance = 200
    private let maximumCameraDistance: CLLocationDistance = 20_000

    /// ピンチが始まった時点の距離。`scale` はジェスチャ開始からの累積倍率なので、
    /// 毎回この基準から割り直す。1 回ぶんずつ掛けていくと誤差が溜まり、
    /// 指を開いて閉じても元の縮尺に戻らなくなる。
    private var zoomBaseDistance: CLLocationDistance?

    /// 回転のジェスチャ中か、と**追従を切って回し始めた時点**の方位・累積角。
    /// 基準を開始時ではなくここで取るのは、切るまでは追従が続いていて
    /// 方位が動き続けるため。開始時に取ると、切り替わった瞬間に飛ぶ。
    private var isRotatingByGesture = false
    private var rotationBaseHeading: CLLocationDirection?
    private var rotationBaseAngle: CGFloat = 0
    /// 追従を切るのに必要な回転量（ラジアン、約 3 度）。
    /// **CarPlay はピンチと回転を同時に認識する**（`CPSMapTemplateViewController` の
    /// `gestureRecognizer:shouldRecognizeSimultaneouslyWithGestureRecognizer:` が
    /// YES を返すのはこの組み合わせだけ。iOS 26.5 で確認）。縮尺を変えるつもりの
    /// ピンチでも指が傾いた拍子に回転が始まるので、そこで追従を切ると
    /// ズームで避けたはずの「縮小しただけで自車を見失う」がそのまま起きる。
    private let minimumRotationToStopFollowing: CGFloat = 0.05

    /// ピッチの最中かどうかと、直前に受け取った 2 本指の中心。
    /// CarPlay はピッチだけ**動かした量を渡してこない**（中心座標のみ）ので、
    /// 前回との差から自分で作る。最初の 1 回は基準を取るだけで何もしない。
    private var isPitchingByGesture = false
    private var lastPitchCenter: CGPoint?

    /// 傾きの上限。これ以上寝かせると奥が潰れて、次の交差点までの道が読めなくなる。
    /// `cameraDistance` と違って傾きは保存していない（`pitch(towards:)` が毎回
    /// `mapView.camera.pitch` から積み直す）ので、同期のための上限ではなく見た目の判断。
    private let maximumPitch: CGFloat = 60
    /// 指を 1pt 滑らせたときに傾ける角度。300pt で上限に届く見当。
    /// **実車で触っていないので、重い・軽いはまずここを動かして調整する。**
    private let pitchDegreesPerPoint: CGFloat = 0.2

    init(style: Style = .full) {
        self.style = style
        // ダッシュボードは面積が小さいので、同じ高度だと何も読み取れない。近づける。
        cameraDistance = style.isWide ? 500 : 300
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Storyboard からは生成しない")
    }

    /// 車から渡される昼夜の指定を反映する（ガイド p.35）。
    /// MKMapView は trait collection に追従するので、上書きするだけで地図ごと切り替わる。
    ///
    /// センターディスプレイ専用。ダッシュボードのシーンには contentStyle が無く、
    /// 窓の trait collection がそのまま昼夜を運んでくるので何もしなくてよい。
    func apply(contentStyle: UIUserInterfaceStyle) {
        overrideUserInterfaceStyle = contentStyle
    }

    override func loadView() {
        mapView.delegate = self
        mapView.showsUserLocation = true
        mapView.showsCompass = false
        mapView.showsScale = false
        // 渋滞は**センターディスプレイでだけ**出す。Dashboard とメーター内は
        // 狭くて経路の線と見分けが付かず、赤い線が増えるだけになる。
        mapView.showsTraffic = style.isWide
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        view = mapView
    }

    // MARK: - ルート表示

    func show(route: NavRoute?) {
        if let routeOverlay {
            mapView.removeOverlay(routeOverlay)
            self.routeOverlay = nil
        }
        mapView.removeAnnotations(routeAnnotations)
        routeAnnotations = []

        guard let route else { return }

        mapView.addOverlay(route.polyline, level: .aboveRoads)
        routeOverlay = route.polyline

        // ダッシュボードとメーター内ではピンを出さない。狭い画面では読み取れないうえ、
        // ガイドが求める「clutter の少ない最小限の地図」から外れる。
        guard style.isWide else { return }

        routeAnnotations = (route.waypoints + [route.destination]).map { place in
            let pin = MKPointAnnotation()
            pin.coordinate = place.coordinate
            pin.title = place.name
            return pin
        }
        mapView.addAnnotations(routeAnnotations)
    }

    // MARK: - カメラ

    /// 連続するジェスチャの最中は `animated: false` で呼ぶ。毎秒何十回も来るので、
    /// アニメーションを掛けると重なって指から遅れる。
    func follow(location: CLLocation, animated: Bool = true) {
        guard isFollowingUser else { return }

        let orientation = self.orientation
        let camera = MKMapCamera(lookingAtCenter: location.coordinate,
                                 fromDistance: cameraDistance,
                                 pitch: orientation.pitch,
                                 heading: heading(for: location, orientation: orientation))
        mapView.setCamera(camera, animated: animated)
    }

    private func heading(for location: CLLocation, orientation: MapOrientation) -> CLLocationDirection {
        switch orientation {
        case .north:
            return 0
        case .heading:
            // 停車中は course が -1 になる。そのときは向きを変えず、地図が回るのを防ぐ。
            return location.course >= 0 ? location.course : mapView.camera.heading
        }
    }

    /// この画面が使う向き。メーター内は進行方向を上にすることがガイド p.55 の要件なので、
    /// 利用者の設定に関係なく固定する。
    private var orientation: MapOrientation {
        style == .cluster ? .heading : MapOrientation.current
    }

    /// 向きの切り替えをその場で反映する。次の位置更新を待たせない。
    ///
    /// 追従中は `follow` に任せ、地図を動かして見ている最中は中心を保ったまま向きだけ変える。
    /// ズーム（`setCameraDistance`）と同じ分岐。
    func apply(orientation: MapOrientation) {
        // メーター内は固定なので何もしない。
        guard style != .cluster else { return }

        if isFollowingUser, let location = LocationService.shared.location {
            follow(location: location)
        } else {
            let camera = mapView.camera
            camera.heading = orientation == .north ? 0 : camera.heading
            camera.pitch = orientation.pitch
            mapView.setCamera(camera, animated: true)
        }
    }

    /// 方位磁針を出すかどうか。メーター内では車が可否を指示してくる
    /// （`CPInstrumentClusterController.compassSetting`）ので、それに従う。
    func setCompassVisible(_ visible: Bool) {
        mapView.showsCompass = visible
    }

    func setFollowingUser(_ following: Bool) {
        isFollowingUser = following
    }

    /// ルート全体が入るように引く。
    func showRouteOverview(_ route: NavRoute) {
        isFollowingUser = false
        let camera = MKMapCamera(lookingAtCenter: mapView.camera.centerCoordinate,
                                 fromDistance: mapView.camera.altitude,
                                 pitch: 0,
                                 heading: 0)
        mapView.setCamera(camera, animated: false)
        mapView.setVisibleMapRect(route.polyline.boundingMapRect,
                                  edgePadding: overviewPadding,
                                  animated: true)
    }

    /// 追従へ戻すときは、進行中の回転・傾けの基準も捨てる。残したままだと、指を離すまで
    /// `rotate` / `pitch` がカメラを書き続ける一方で、追従が戻っているので位置更新のたびに
    /// `follow` が書き戻し、1 秒ごとにガタついたあげく回した角度も残らない。
    /// **指が触れている最中にもここへ来る**（リルートの成功・到着・案内開始で
    /// `apply(phase:)` が呼ぶ）。ズームは追従したまま効かせる操作なので触らない。
    func recenter() {
        isFollowingUser = true
        isRotatingByGesture = false
        rotationBaseHeading = nil
        isPitchingByGesture = false
        lastPitchCenter = nil
        if let location = LocationService.shared.location {
            follow(location: location)
        }
    }

    func zoomIn() {
        setCameraDistance(baseCameraDistance / 2)
    }

    func zoomOut() {
        setCameraDistance(baseCameraDistance * 2)
    }

    /// ズームの基準にする距離。追従中は `cameraDistance` がそのまま効いているので
    /// 保存値を使う（`follow` のアニメーションが飛んでいる最中に実カメラを読むと
    /// 途中の値を掴む）。いっぽう `showRouteOverview` は `setVisibleMapRect` で
    /// カメラだけを引いて保存値を更新しないので、追従していないときは実カメラから取る。
    /// 保存値のまま基準にすると、全体表示に指が触れた瞬間そこへ跳ぶ。
    private var baseCameraDistance: CLLocationDistance {
        isFollowingUser ? cameraDistance : mapView.camera.centerCoordinateDistance
    }

    /// 丸めるのは**保存する値**。適用時にだけ丸めて `cameraDistance` を無制限に
    /// 貯めると、限界まで縮めたあと指を戻しても、貯めたぶんを吐き出すまで反応しない。
    ///
    /// 入れる先は `altitude`（地面からの高さ）ではなく `centerCoordinateDistance`
    /// （中心までの距離）。`follow` が `fromDistance:` に渡しているのがこちらで、
    /// 傾いた地図では 2 つが `cos(pitch)` ぶんずれる。混ぜると、ピンチを始めた瞬間に
    /// 縮尺が跳ねる。
    private func setCameraDistance(_ distance: CLLocationDistance, animated: Bool = true) {
        cameraDistance = min(max(distance, minimumCameraDistance), maximumCameraDistance)
        if let location = LocationService.shared.location, isFollowingUser {
            follow(location: location, animated: animated)
        } else {
            let camera = mapView.camera
            camera.centerCoordinateDistance = cameraDistance
            mapView.setCamera(camera, animated: animated)
        }
    }

    /// パン操作。指のドラッグ（タッチ対応の車）とノブ／トラックパッドの方向入力の
    /// どちらもここに来る。指に追従させたいドラッグ中は `animated: false` で呼ぶ。
    ///
    /// 画面を動かした向きに地図の中身が付いてくるよう、中心は逆向きへ動かす。
    func pan(by translation: CGPoint, animated: Bool = true) {
        isFollowingUser = false
        let point = CGPoint(x: mapView.bounds.midX - translation.x,
                            y: mapView.bounds.midY - translation.y)
        mapView.setCenter(mapView.convert(point, toCoordinateFrom: mapView), animated: animated)
    }

    // MARK: - タッチジェスチャ（iOS 26）

    func beginZoomGesture() {
        zoomBaseDistance = baseCameraDistance
    }

    /// `scale` はジェスチャ開始からの累積倍率。指を広げる（1 より大きい）と近づく。
    ///
    /// **拡大の中心は指のあいだではなく画面の中央のまま**。追従中は中央が自車なので、
    /// 指の位置へ寄せると自車が画面の外へ出てしまう。CarPlay 自身もダブルタップの
    /// 中心にタップ位置ではなく安全領域の中心を渡してくるので、揃えている。
    ///
    /// 追従は切らない。拡大・縮小ボタンと同じ扱いで、中心を動かす操作ではないため
    /// （切ると、縮小しただけで自車を見失う）。
    func zoom(toScale scale: CGFloat) {
        guard let zoomBaseDistance, scale > 0 else { return }
        setCameraDistance(zoomBaseDistance / scale, animated: false)
    }

    func endZoomGesture() {
        zoomBaseDistance = nil
    }

    /// 回転とピッチは**追従をやめてからでないと効かない**。`follow` が位置更新のたびに
    /// 向きと傾きを `MapOrientation` から作り直すので、追従したまま回しても 1 秒で戻る。
    /// パンと同じ扱いにして、戻るのは現在地ボタンに任せる。
    ///
    /// ただし**開始を受けた時点では切らない**。ピンチと同時に認識されるため、
    /// ここで切るとただの拡大縮小でも追従が落ちる（`minimumRotationToStopFollowing`）。
    ///
    /// メーター内は進行方向を上に固定するのがガイド p.55 の要件なので受け付けない。
    /// いまジェスチャが来るのはセンターディスプレイだけだが、この判断はカメラを持つ
    /// このクラスに置いておく（`apply(orientation:)` と同じ形）。
    func beginRotationGesture() {
        guard style != .cluster else { return }
        isRotatingByGesture = true
        rotationBaseHeading = nil
    }

    /// `rotation` はジェスチャ開始からの累積角（ラジアン、時計回りが正）。
    /// 地図の中身を時計回りに回すと画面の上を向く方位は反時計回りに動くので、符号を反転する。
    func rotate(byRadians rotation: CGFloat) {
        guard isRotatingByGesture else { return }

        guard let rotationBaseHeading else {
            // はっきり回したと分かってから追従を切り、その瞬間の向きを基準にする。
            guard abs(rotation) >= minimumRotationToStopFollowing else { return }
            isFollowingUser = false
            self.rotationBaseHeading = mapView.camera.heading
            rotationBaseAngle = rotation
            return
        }

        let camera = mapView.camera
        camera.heading = normalized(rotationBaseHeading - Double(rotation - rotationBaseAngle) * 180 / .pi)
        mapView.setCamera(camera, animated: false)
    }

    func endRotationGesture() {
        isRotatingByGesture = false
        rotationBaseHeading = nil
    }

    func beginPitchGesture() {
        guard style != .cluster else { return }
        isPitchingByGesture = true
        lastPitchCenter = nil
    }

    /// 2 本指を上へ滑らせると寝かせる（傾きを増やす）。Apple 純正の地図と同じ向き。
    /// CarPlay は中心座標しか渡してこないので、前回との差を動かした量として使う。
    ///
    /// 回転と同じく、**実際に傾ける段になってから**追従を切る。開始だけで切ると、
    /// 指が触れただけで自車を見失う。
    func pitch(towards center: CGPoint) {
        guard isPitchingByGesture else { return }
        defer { lastPitchCenter = center }
        guard let lastPitchCenter, lastPitchCenter.y != center.y else { return }

        isFollowingUser = false
        let camera = mapView.camera
        camera.pitch = min(max(camera.pitch + (lastPitchCenter.y - center.y) * pitchDegreesPerPoint, 0),
                           maximumPitch)
        mapView.setCamera(camera, animated: false)
    }

    func endPitchGesture() {
        isPitchingByGesture = false
        lastPitchCenter = nil
    }

    /// `CarPlayGestureLog` へ渡すカメラの要約。渡した値と出た結果を 1 行に並べるためだけの
    /// もので、判断には使わない。追従を併記しているのは、回転・ピッチが**追従を切ってから
    /// でないと効かない**ため。`off` になっていないのに動かないのと、`off` なのに動かないのは
    /// 原因が別（前者は追従を切る条件、後者は係数と符号）。
    var cameraSummary: String {
        let camera = mapView.camera
        return String(format: "heading=%.1f pitch=%.1f distance=%.0f follow=%@",
                      camera.heading, camera.pitch, camera.centerCoordinateDistance,
                      isFollowingUser ? "on" : "off")
    }

    /// 方位を 0 以上 360 未満に収める。`rotationBaseHeading - 累積角` は指を大きく回せば
    /// 平気で ±360 を超える。MKMapView も `setCamera` で自前に丸めるが、
    /// `maximumPitch` と同じで、丸め方を MapKit に当てにせず渡す前に揃えておく。
    private func normalized(_ heading: CLLocationDirection) -> CLLocationDirection {
        let value = heading.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }

    /// テンプレートが重なっている領域を避けるための余白。
    private var overviewPadding: UIEdgeInsets {
        let insets = view.safeAreaInsets
        return UIEdgeInsets(top: insets.top + 16,
                            left: insets.left + 16,
                            bottom: insets.bottom + 16,
                            right: insets.right + 16)
    }
}

extension CarPlayMapViewController: MKMapViewDelegate {
    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let polyline = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }

        let renderer = MKPolylineRenderer(polyline: polyline)
        renderer.strokeColor = UIColor.systemBlue
        renderer.lineWidth = style.isWide ? 10 : 8
        renderer.lineCap = .round
        renderer.lineJoin = .round
        return renderer
    }
}
