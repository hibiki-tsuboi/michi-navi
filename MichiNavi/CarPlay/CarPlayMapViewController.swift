import CarPlay
import MapKit

/// ジェスチャをカメラへ実際に反映したかどうか。反映しなかった理由まで持たせているのは、
/// **どれも「地図が動かない」というまったく同じ見え方になる**ため。ログで分けられないと、
/// 実車で一度しか試せない場面で、受け付けていないだけのものを係数や符号の誤りと取り違える。
enum GestureOutcome: String {
    /// カメラを動かした。
    case applied
    /// そもそも受け付けていない。開始が届いていない（中断されたジェスチャに終了は来ないので
    /// 印が食い違うことがある）、`recenter()` に基準を捨てられた、メーター内で禁じている、のいずれか。
    case inactive
    /// 受け付けてはいるが、まだ動かす段ではない。追従を切るしきい値の手前と、
    /// ピッチの最初の 1 点（差を取る相手がまだ無い）。
    case pending
}

/// ログへ渡すカメラの状態。整形はログ側が持つ（本番のコードに出力書式を置かない）。
struct CameraState {
    /// **方位の絶対値ではなく、前回この値を作ってからの変化**。追従中の `heading` は
    /// `location.course` そのもので、載せると位置情報になる。しかも `.public` で出す以上、
    /// ログアーカイブや sysdiagnose にそのまま残って、Apple や車のベンダーへ渡る。
    /// 回転の確認に要るのは「どちらへどれだけ動いたか」だけなので、差だけを持つ。
    let headingDelta: CLLocationDirection
    let pitch: CGFloat
    let distance: CLLocationDistance
    let isFollowingUser: Bool
    /// 傾き・距離が上限（下限）に張り付いているか。**張り付いているあいだは入力だけが動いて
    /// 出力が止まる**ので、係数や符号を間違えたときとまったく同じ見え方になる。
    let pitchIsClamped: Bool
    let distanceIsClamped: Bool
}

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
    /// 通ってきたところ。経路の線の**上に**重ねて塗り替える。
    private var travelledOverlay: TravelledPolyline?
    /// 最後に塗り替えた地点までの距離。これだけ進むまで引き直さない。
    private var travelledDistance: CLLocationDistance?

    /// 塗り替えを引き直す間隔。時速 60km ならおよそ 3 秒に 1 回。
    private static let travelledStep: CLLocationDistance = 50
    /// 通ってきたところの色。**不透明**（下に経路の青が敷いてある）。
    ///
    /// 昼夜で入れ替わらない固定色にしてある。`systemGray` のような動的な色は
    /// 夜に明るくなるので、**済んだところが残りより目立つ**という逆の効き方をする
    /// （地図の昼夜は `overrideUserInterfaceStyle` で切り替わるので、動的な色はここでも効く）。
    private static let travelledColor = UIColor(white: 0.45, alpha: 1)

    /// これまでに走った道（`TrackStore`）。**線ごとに 1 本**持って、伸びたものだけ引き直す。
    private var trackOverlays: [UUID: MKPolyline] = [:]
    /// 走った道の色。**半透明**——済んだぶんの灰とは逆で、こちらは経路の下に敷く下地なので、
    /// 地図の道路が透けたほうが「記録を重ねた」ように見える（塗り替えではない）。
    ///
    /// 色は 2026-08-24 に実地図の上で決めた（`MKMapSnapshotter` の画像に候補を重ねて
    /// 昼夜ぶん描き出す。済んだぶんの灰を決めたときと同じ手）。**落ちた候補に理由がある**——
    /// オレンジは**地図が高速道路に使っている色**、緑は**公園の緑**と混ざる。灰は済んだぶんと
    /// 見分けが付かない（まさに区別したい 2 つ）。薄い青は残りの経路に見えるうえ、
    /// 昼の地図では鉄道の線に紛れて消える。**マゼンタだけが地図の側で使われていない。**
    private static let trackColor = UIColor(red: 0.85, green: 0.2, blue: 0.6, alpha: 0.7)
    /// 走った道の太さ。**経路より細く**（案内の線が主役で、こちらは下地）。
    ///
    /// 2026-09-05 に経路を 10 から 8 へ落としたときも**この値は動かしていない**。
    /// 比は 2.5 倍から 2 倍に縮むが、半分の太さ・半透明・地図が使っていない色の 3 つで
    /// 下地として読めるはず、という判断。**まだ CarPlay の地図に敷いたところを
    /// 見ていない**ので、見ていない値を推測で動かさない（→「未実装」）。
    private static let trackWidth: CGFloat = 4

    /// 経由地と目的地のピン。広い画面でだけ出す。
    private var routeAnnotations: [MKPointAnnotation] = []

    /// 自車を追従する（案内中）か、地図を自由に見せる（パン中・全体表示中）か。
    private(set) var isFollowingUser = true {
        didSet {
            guard oldValue != isFollowingUser else { return }
            onFollowingChanged?(isFollowingUser)
        }
    }

    /// 追従が入り切りした合図。**マップボタンを貼り直す**ために要る。
    /// 現在地ボタンとパンボタンは 4 つしかない枠の同じ場所を分け合っているので、
    /// 切り替わった瞬間に貼り直さないと「追従が外れているのに戻すボタンが無い」が起きる。
    var onFollowingChanged: ((Bool) -> Void)?

    /// 追従時のカメラ高度。ズームボタンとピンチで上下する。
    private var cameraDistance: CLLocationDistance
    private let minimumCameraDistance: CLLocationDistance = 200
    private let maximumCameraDistance: CLLocationDistance = 20_000

    /// 保存値と実カメラがずれている印。カメラを動かす経路のうち `showRouteOverview` だけが
    /// `setVisibleMapRect` でカメラを引いて `cameraDistance` を更新しないので、そのあいだだけ立てる。
    private var cameraDistanceIsStale = false

    /// カメラを一度でも意味のある場所へ置いたか。**起動直後の 1 回だけアニメーションを
    /// 外すため**に要る。`MKMapView` は生成した時点では端末の地域＝日本全体を映していて、
    /// そこは自車位置とも経路とも何の関係も無い。最初の当て込みを `animated: true` の
    /// まま通すと、**日本全体から数秒かけて現在地へ寄ってくる**。`showRouteOverview` が
    /// 前の全体表示から飛ぶのを止めているのとまったく同じ話で、**関係の無い枠から飛ぶ
    /// 動きは何も伝えていない**。しかもこちらは繋いだ直後——運転者が最初に見る数秒——に
    /// 起きる。カーナビは繋いだ瞬間から走行縮尺で描き始めるものなので、1 フレーム目には
    /// もう自車の上に居るのが正しい。
    private var hasPlacedCamera = false

    /// いま全体表示で見せている経路。テンプレート（ルート提示の一覧・案内カード）が
    /// 出入りすると使える幅が変わり、当て込みはその幅から決まるので、変わったときに
    /// 合わせ直すために覚えておく（[viewSafeAreaInsetsDidChange]）。
    /// **利用者が地図を動かしたら捨てる**（[abandonOverview]）。
    private var overviewRoute: NavRoute?

    /// 前回ログへ渡した方位。差だけを載せるために覚えておく（[CameraState.headingDelta]）。
    private var lastReportedHeading: CLLocationDirection?

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

    /// **1 フレーム目から走行縮尺で描く。**
    ///
    /// CarPlay を繋ぐ前から iPhone 側が測位している（`LocationService` は共有なので、
    /// シーンが増えても GPS は 1 本のまま走り続けている）ので、たいていはここで自車位置が
    /// もう分かっている。**最初の測位を待つと、そのあいだ日本全体が映る**。
    /// 分からないときは [hasPlacedCamera] が受けて、最初の測位でアニメーション無しに置く。
    override func viewDidLoad() {
        super.viewDidLoad()
        guard let location = LocationService.shared.location else { return }
        follow(location: location, animated: false)
    }

    // MARK: - ルート表示

    func show(route: NavRoute?) {
        if let routeOverlay {
            mapView.removeOverlay(routeOverlay)
            self.routeOverlay = nil
        }
        // **経路が入れ替わったら通ったぶんも捨てる。** 引き直した経路は現在地から
        // 引き直されているので、前の経路で塗ったぶんはどこにも対応しない。
        clearTravelled()
        mapView.removeAnnotations(routeAnnotations)
        routeAnnotations = []

        guard let route else { return }

        mapView.addOverlay(route.polyline, level: .aboveRoads)
        routeOverlay = route.polyline

        // ダッシュボードとメーター内ではピンを出さない。狭い画面では読み取れないうえ、
        // ガイドが求める「clutter の少ない最小限の地図」から外れる。
        guard style.isWide else { return }

        routeAnnotations = (route.displayedWaypoints + [route.destination]).map { place in
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
    /// 通ってきたところを塗り替える。
    ///
    /// **効くのはおもに全体表示**。案内中のカメラは自車の後ろから前を向いているので、
    /// 通ったぶんは画面の下端から外れている。全体表示にしたときと、曲がった直後に
    /// 後ろへ伸びる線が「どこまで来たか」を示す。
    ///
    /// **経路の線の上に重ねて隠す**（残りぶんを描き直すのではなく）。あちらは数千点
    /// あって、進むたびに作り直すと 1 秒ごとに全長ぶんの点を舐めることになる。
    /// **そのぶん色は不透明でなければならない**——透かすと下の青が出るだけで、
    /// 地図が透けるわけではない。
    func showTravelled(_ progress: RouteProgress, of route: NavRoute) {
        let travelled = max(0, route.distance - progress.distanceRemaining)
        // 毎秒引き直さない。数メートルでは絵が変わらないので、作り直すだけ無駄。
        if let travelledDistance, abs(travelled - travelledDistance) < Self.travelledStep { return }

        clearTravelled()
        travelledDistance = travelled

        let coordinates = route.travelled(remaining: progress.distanceRemaining)
        guard coordinates.count >= 2 else { return }

        let line = TravelledPolyline(coordinates: coordinates, count: coordinates.count)
        // 経路より**あとに**足す。同じ level なら後から足したほうが上に描かれる。
        mapView.addOverlay(line, level: .aboveRoads)
        travelledOverlay = line
    }

    /// これまでに走った道を敷く。**案内には一切関わらない**（`TrackStore` が
    /// `NavigationController` ではなく `LocationService` を直に見ているのと同じ理由で、
    /// いちばん塗りたいのは案内していない道）。
    ///
    /// **広い画面だけ。** ダッシュボードとメーター内は「clutter の少ない最小限の地図」が
    /// 要件（ガイド p.54-55）で、目的地ピンを出していないのと同じ判断。走った道は
    /// 案内に要らない情報なので、狭い画面では真っ先に落ちる側になる。
    func showTracks(_ tracks: [TrackStore.Track]) {
        guard style.isWide else { return }

        let changes = Self.trackChanges(for: tracks, drawn: trackOverlays.mapValues(\.pointCount))
        for id in changes.remove {
            guard let line = trackOverlays.removeValue(forKey: id) else { continue }
            mapView.removeOverlay(line)
        }
        for track in tracks where changes.redraw.contains(track.id) {
            let line = TrackPolyline(coordinates: track.coordinates, count: track.coordinates.count)
            // **必ず先頭へ差し込む。** 同じ level では後から足したものが上に描かれるので、
            // `addOverlay` にすると経路より先に足した線だけが下に入る（走っている最中に
            // 伸びた線は経路の上に乗ってしまう）。
            mapView.insertOverlay(line, at: 0, level: .aboveRoads)
            trackOverlays[track.id] = line
        }
    }

    /// 引き直す線と、地図から外す線。
    ///
    /// **選ぶところを描くところから離してある**ので、地図を持たずに確かめられる
    /// （`JunctionGeometry` ↔ `JunctionImage` と同じ分け方）。`drawn` はいま地図に載って
    /// いる線の点の数。
    static func trackChanges(for tracks: [TrackStore.Track], drawn: [UUID: Int]) -> TrackChanges {
        var changes = TrackChanges()
        var stale = Set(drawn.keys)

        for track in tracks where track.coordinates.count >= 2 {
            stale.remove(track.id)
            // **伸びた線だけ引き直す。** 走っているあいだ点が増えるのは最後の 1 本だけで、
            // 点の数が同じなら絵は変わらない（`$tracks` は 50m ごとに流れてくる）。
            guard drawn[track.id] != track.coordinates.count else { continue }
            changes.redraw.insert(track.id)
            // 伸びたぶんは載せ替えになるので、古いほうを先に外す。
            if drawn[track.id] != nil { changes.remove.insert(track.id) }
        }
        // 残ったものは消えた線（利用者が記録を消した）。
        changes.remove.formUnion(stale)
        return changes
    }

    private func clearTravelled() {
        if let travelledOverlay {
            mapView.removeOverlay(travelledOverlay)
            self.travelledOverlay = nil
        }
        travelledDistance = nil
    }

    func follow(location: CLLocation, animated: Bool = true) {
        guard isFollowingUser else { return }

        // ここから先は `cameraDistance` をそのままカメラへ入れる。保存値が真になるので印を下ろす。
        cameraDistanceIsStale = false
        let orientation = self.orientation
        let camera = MKMapCamera(lookingAtCenter: location.coordinate,
                                 fromDistance: cameraDistance,
                                 pitch: orientation.pitch,
                                 heading: heading(for: location, orientation: orientation))
        // **初回だけは頼まれても動かさない。** 飛んでくる元は日本全体で、自車位置とは
        // 何の関係も無い（[hasPlacedCamera]）。
        mapView.setCamera(camera, animated: animated && hasPlacedCamera)
        hasPlacedCamera = true
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

        abandonOverview()
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
    ///
    /// **動かしてよいのは自車から引くときだけ。** 前の全体表示が残っている状態から
    /// 当て込むと、`setVisibleMapRect` は**そこから**新しい経路まで飛ぶ。前の行き先が
    /// 遠ければ縮尺は数百 km になっているので（実測: 500km の経路で 997km）、次に
    /// 近所を選んだときに**日本全体から数秒かけて寄ってくる**ことになる。**その飛行は
    /// 何も伝えていない**——前の枠と新しい経路に関係が無いため。自車から引くぶんには
    /// 「いまここ」から「経路はこれ」への繋がりが見えるので残す。
    ///
    /// なお直後に `viewSafeAreaInsetsDidChange` がアニメーション無しで当て直すことが多い
    /// （ルート提示の一覧が出て使える幅が変わるため）。飛んでいる途中で snap するくらいなら、
    /// 初めから動かさないほうが揃う。
    func showRouteOverview(_ route: NavRoute) {
        // **自車から引くときでも、まだ一度もカメラを置いていなければ動かさない。**
        // 起動直後にここへ来る道がある（iPhone で候補を出したまま CarPlay を繋ぐと、
        // `apply(phase:)` が購読した時点の `.previewing` をそのまま反映する）。
        // そのとき飛んでくる元は前の全体表示ではなく日本全体だが、関係が無いことは同じ。
        let animated = isFollowingUser && hasPlacedCamera
        isFollowingUser = false
        overviewRoute = route
        // 引いた先の高度は MapKit が決めるので、保存値はここで当てにならなくなる。
        cameraDistanceIsStale = true
        // **`altitude` ではなく `centerCoordinateDistance`。** 傾いた地図では 2 つが
        // `cos(pitch)` ぶんずれる（実測: 距離 499m・pitch 45 で altitude 353m、
        // pitch 60 で 249m）。混ぜると、平らにした拍子に縮尺が跳ねる。
        let camera = MKMapCamera(lookingAtCenter: mapView.camera.centerCoordinate,
                                 fromDistance: mapView.camera.centerCoordinateDistance,
                                 pitch: 0,
                                 heading: 0)
        mapView.setCamera(camera, animated: false)
        hasPlacedCamera = true
        fitOverview(route, animated: animated)
    }

    private func fitOverview(_ route: NavRoute, animated: Bool) {
        mapView.setVisibleMapRect(route.polyline.boundingMapRect,
                                  edgePadding: overviewPadding,
                                  animated: animated)
    }

    /// **ルート提示の一覧は当て込みのあとに出てくる**（`CarPlayCoordinator.apply(phase:)` の
    /// 順序）。出た時点で使える幅が変わるが、`setVisibleMapRect` は中心と縮尺を決めるだけで
    /// あとから追随しないので、そのままだと経路が一覧の裏に入る。**テンプレートの出入りを
    /// 知る手段はここしかない**（`CPMapTemplateDelegate` に提示の合図は無い）。
    ///
    /// 出入りのアニメーションに重ねないよう、合わせ直しはアニメーション無しで行う。
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        guard let overviewRoute else { return }
        fitOverview(overviewRoute, animated: false)
    }

    /// 全体表示の追随を打ち切る。**利用者が自分でカメラを動かしたら**、テンプレートの
    /// 出入りで当て込み直さない。残すと、動かした先からひとりでに引き戻される。
    private func abandonOverview() {
        overviewRoute = nil
    }

    /// 追従へ戻すときは、進行中の回転・傾けの基準も捨てる。残したままだと、指を離すまで
    /// `rotate` / `pitch` がカメラを書き続ける一方で、追従が戻っているので位置更新のたびに
    /// `follow` が書き戻し、1 秒ごとにガタついたあげく回した角度も残らない。
    /// **指が触れている最中にもここへ来る**（リルートの成功・到着・案内開始で
    /// `apply(phase:)` が呼ぶ）。ズームは追従したまま効かせる操作なので触らない。
    ///
    /// **戻すのは一瞬で。** ここへ来る道のうちいちばん多いのは全体表示からの復帰で、
    /// そのとき飛ぶ距離は経路の長さそのもの（実測: 500km の経路を当て込むと縮尺は
    /// 997km）。`animated: true` のままだと、**遠い行き先を選んだときほど長く待たされる**。
    /// 押した人は「いまの案内へ戻せ」と言っているのであって、戻る途中を見たいのではない。
    /// `follow` の毎秒の更新は動かしたままにする（あちらは 1 秒ぶんの隙間を埋めるもので、
    /// 止めると自車が飛び飛びに動く）。
    func recenter() {
        isFollowingUser = true
        abandonOverview()
        isRotatingByGesture = false
        rotationBaseHeading = nil
        isPitchingByGesture = false
        lastPitchCenter = nil
        if let location = LocationService.shared.location {
            follow(location: location, animated: false)
        }
    }

    func zoomIn() {
        setCameraDistance(baseCameraDistance / 2)
    }

    func zoomOut() {
        setCameraDistance(baseCameraDistance * 2)
    }

    /// ズームの基準にする距離。原則は保存値の `cameraDistance`。**実カメラを読むのは
    /// `showRouteOverview` の直後だけ**で、あそこは `setVisibleMapRect` でカメラだけを引いて
    /// 保存値を更新しないため、保存値のまま基準にすると全体表示に指が触れた瞬間そこへ跳ぶ。
    ///
    /// 追従の有無では分けない。**パン UI に入ると `setFollowingUser(false)` されたうえで
    /// 拡大・縮小ボタンだけが残る**ので、追従していないことがズームボタンにとっての通常の
    /// 状態になる。そこで実カメラを読むと、`animated: true` で飛んでいる最中の途中の値を
    /// 掴み、連打するほど 1 回ぶんの効きが小さくなる（500 → 250 の途中で 420 を読んで 210 を狙う）。
    private var baseCameraDistance: CLLocationDistance {
        cameraDistanceIsStale ? mapView.camera.centerCoordinateDistance : cameraDistance
    }

    /// ピンチの基準を持っているか。**開始が届いていないなら、それはピンチの更新ではありえない。**
    /// タップの見分けに使う（`CarPlayCoordinator` の `didUpdateZoomGesture`）。
    var hasZoomBase: Bool { zoomBaseDistance != nil }

    /// 丸めるのは**保存する値**。適用時にだけ丸めて `cameraDistance` を無制限に
    /// 貯めると、限界まで縮めたあと指を戻しても、貯めたぶんを吐き出すまで反応しない。
    ///
    /// 入れる先は `altitude`（地面からの高さ）ではなく `centerCoordinateDistance`
    /// （中心までの距離）。`follow` が `fromDistance:` に渡しているのがこちらで、
    /// 傾いた地図では 2 つが `cos(pitch)` ぶんずれる。混ぜると、ピンチを始めた瞬間に
    /// 縮尺が跳ねる。
    private func setCameraDistance(_ distance: CLLocationDistance, animated: Bool = true) {
        cameraDistance = min(max(distance, minimumCameraDistance), maximumCameraDistance)
        cameraDistanceIsStale = false
        abandonOverview()
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
    ///
    /// 戻すのは**動いた距離（メートル）**。ログに載せる結果がこれしか無いためで、行き先の座標を
    /// 載せると位置情報になる。パンだけは `heading` も `pitch` も `distance` も動かさないので、
    /// カメラの要約を並べても「効いたのか」が分からない。
    @discardableResult
    func pan(by translation: CGPoint, animated: Bool = true) -> CLLocationDistance {
        isFollowingUser = false
        abandonOverview()
        let before = mapView.centerCoordinate
        let anchor = centerPoint
        let point = CGPoint(x: anchor.x - translation.x, y: anchor.y - translation.y)
        let after = mapView.convert(point, toCoordinateFrom: mapView)
        mapView.setCenter(after, animated: animated)
        return MKMapPoint(before).distance(to: MKMapPoint(after))
    }

    /// 中心座標がいま画面のどこに描かれているか。**`bounds` の中心ではない。**
    /// `MKMapView` は中心座標を安全領域の中心に置く（`layoutMargins` が既定で安全領域を
    /// 含むため）。CarPlay ではそれを作るのが上部バーと案内カードなので、案内中は
    /// 縦にも横にもずれる。
    ///
    /// **`bounds` の中心で座標を読んで `setCenter` へ渡してはいけない。** 読んだ点と
    /// 置かれる点が違うので、渡すたびにその差ぶん地図が飛ぶ。指を止めていても飛ぶうえ、
    /// ドラッグは毎秒 60 回来るので積み上がる（iPhone の 14pt でも 1 秒で 250m 以上、
    /// 240pt のドラッグが 4.5 倍動く。iOS 26.2 で実測）。
    private var centerPoint: CGPoint {
        mapView.convert(mapView.centerCoordinate, toPointTo: mapView)
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
    @discardableResult
    func zoom(toScale scale: CGFloat) -> GestureOutcome {
        guard let zoomBaseDistance, scale > 0 else { return .inactive }
        setCameraDistance(zoomBaseDistance / scale, animated: false)
        return .applied
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
    @discardableResult
    func rotate(byRadians rotation: CGFloat) -> GestureOutcome {
        guard isRotatingByGesture else { return .inactive }

        guard let rotationBaseHeading else {
            // はっきり回したと分かってから追従を切り、その瞬間の向きを基準にする。
            guard abs(rotation) >= minimumRotationToStopFollowing else { return .pending }
            isFollowingUser = false
            abandonOverview()
            self.rotationBaseHeading = mapView.camera.heading
            rotationBaseAngle = rotation
            return .pending
        }

        let camera = mapView.camera
        camera.heading = normalized(rotationBaseHeading - Double(rotation - rotationBaseAngle) * 180 / .pi)
        mapView.setCamera(camera, animated: false)
        return .applied
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
    @discardableResult
    func pitch(towards center: CGPoint) -> GestureOutcome {
        guard isPitchingByGesture else { return .inactive }
        defer { lastPitchCenter = center }
        guard let lastPitchCenter, lastPitchCenter.y != center.y else { return .pending }

        isFollowingUser = false
        abandonOverview()
        let camera = mapView.camera
        camera.pitch = min(max(camera.pitch + (lastPitchCenter.y - center.y) * pitchDegreesPerPoint, 0),
                           maximumPitch)
        mapView.setCamera(camera, animated: false)
        return .applied
    }

    func endPitchGesture() {
        isPitchingByGesture = false
        lastPitchCenter = nil
    }

    /// `CarPlayGestureLog` へ渡すカメラの状態。渡した値と出た結果を 1 行に並べるためだけの
    /// もので、判断には使わない。**呼ぶたびに方位の差の基準が進む**ので、1 行につき 1 回だけ呼ぶこと。
    ///
    /// 距離だけは実カメラではなく保存値を返す。拡大・縮小ボタンとダブルタップは
    /// `animated: true` で適用するので、直後に実カメラを読むと**動く前の値**が出て、
    /// 効いているタップが効いていないように見える。保存値は適用と同時に確定している。
    ///
    /// 追従を併記しているのは、回転・ピッチが**追従を切ってからでないと効かない**ため。
    /// ただし `follow=on` かどうかだけでは足りないので、動かせたかは [GestureOutcome] で別に見る。
    func cameraState() -> CameraState {
        let camera = mapView.camera
        let heading = camera.heading
        let distance = baseCameraDistance
        defer { lastReportedHeading = heading }
        return CameraState(headingDelta: signedDelta(from: lastReportedHeading ?? heading, to: heading),
                           pitch: camera.pitch,
                           distance: distance,
                           isFollowingUser: isFollowingUser,
                           pitchIsClamped: camera.pitch <= 0 || camera.pitch >= maximumPitch,
                           distanceIsClamped: distance <= minimumCameraDistance
                               || distance >= maximumCameraDistance)
    }

    /// 方位の差を -180 以上 180 未満に収める。359 度から 1 度への動きを -358 度と書かないため。
    private func signedDelta(from: CLLocationDirection, to: CLLocationDirection) -> CLLocationDirection {
        let delta = (to - from).truncatingRemainder(dividingBy: 360)
        if delta >= 180 { return delta - 360 }
        if delta < -180 { return delta + 360 }
        return delta
    }

    /// 方位を 0 以上 360 未満に収める。`rotationBaseHeading - 累積角` は指を大きく回せば
    /// 平気で ±360 を超える。MKMapView も `setCamera` で自前に丸めるが、
    /// `maximumPitch` と同じで、丸め方を MapKit に当てにせず渡す前に揃えておく。
    private func normalized(_ heading: CLLocationDirection) -> CLLocationDirection {
        let value = heading.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }

    /// 全体表示の余白。**テンプレートが重なっている領域は `setVisibleMapRect` が
    /// 自分で避ける**ので（`MKMapView.layoutMargins` が既定で安全領域を含む）、
    /// ここで渡すのは見た目の余白だけ。
    ///
    /// **安全領域を足してはいけない。** 二重になり、CarPlay の案内カードのように
    /// 大きな余白があると `left + right` が画面幅を超える。そうなると当て込みが
    /// 破綻して、経路が右へ寄った細い帯に潰れる（実測: 幅 800pt・左 300pt・右 90pt の
    /// 安全領域に対し、足すと余白の合計が 812pt になり、経路が x 604…616 の 12pt に
    /// なった。足さなければ 316…694 に収まる）。しかも**余白を増やすほど経路が
    /// 大きくなる**という逆の効き方をするので、症状から原因を辿りにくい。
    private var overviewPadding: UIEdgeInsets {
        UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    }
}

extension CarPlayMapViewController: MKMapViewDelegate {
    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let polyline = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }

        let renderer = MKPolylineRenderer(polyline: polyline)
        if polyline is TrackPolyline {
            renderer.strokeColor = Self.trackColor
            renderer.lineWidth = Self.trackWidth
        } else {
            renderer.strokeColor = polyline is TravelledPolyline ? Self.travelledColor : UIColor.systemBlue
            // 経路と、その上に重ねる済んだぶんは**同じ太さでなければならない。**
            // 細いと下の青が縁として残り、太いと通っていないところまで塗る。
            //
            // 2026-09-05 に 10 / 8 から落とした（実機の CarPlay で「太い」と言われた）。
            // 遠い画面なので iPhone の 6pt より太くするのは正しいが、**上限は
            // 「地図の道路を覆わないこと」**——走行縮尺（`cameraDistance` 500m）では
            // 1pt がおよそ 0.5m なので、10pt は 2 車線ぶんの幅になり、交差点の形と
            // 分岐の角度が線の下に隠れる。`JunctionImage` が拡大図で足そうとしている
            // ものを、地図の側で消すことになっていた。
            renderer.lineWidth = style.isWide ? 8 : 6
        }
        renderer.lineCap = .round
        renderer.lineJoin = .round
        return renderer
    }
}

/// 走った道の線のうち、引き直すものと外すもの（[CarPlayMapViewController.trackChanges]）。
struct TrackChanges: Equatable {
    var redraw: Set<UUID> = []
    var remove: Set<UUID> = []
}

/// 走った道の線。**型で見分ける**ために分けてある。保持している線と `===` で
/// 照合する手もあるが、こちらは走行の数だけあり、`rendererFor` は線 1 本ごとに
/// 呼ばれるので、照合すると線の数の 2 乗になる。
final class TrackPolyline: MKPolyline {}

/// 通ってきたところの線。**これも型で見分ける。** 1 本しかないので保持している
/// 線と `===` で照合していたが、**それでは色が付かなかった**（2026-09-05 まで
/// 案内中ずっと青いままだった）。`MKMapView` は **`addOverlay` の内側で同期的に**
/// `rendererFor` を呼ぶので、足したあとに代入する書き方では**色を決める瞬間には
/// まだ nil**。しかもレンダラはキャッシュされるため、あとで代入しても直らない。
/// 代入を先へ動かすだけでも通るが、順序でしか守れない決まりをコメントに預けるより、
/// 型にして順序と無関係にするほうが確実（`TrackPolyline` と同じ形になる）。
final class TravelledPolyline: MKPolyline {}
