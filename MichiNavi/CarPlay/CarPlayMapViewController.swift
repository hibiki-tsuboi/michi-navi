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
    }

    private let style: Style
    private let mapView = MKMapView()
    private var routeOverlay: MKPolyline?
    private var destinationAnnotation: MKPointAnnotation?

    /// 自車を追従する（案内中）か、地図を自由に見せる（パン中・全体表示中）か。
    private(set) var isFollowingUser = true

    /// 追従時のカメラ高度。ズームボタンで上下する。
    private var cameraDistance: CLLocationDistance
    private let minimumCameraDistance: CLLocationDistance = 200
    private let maximumCameraDistance: CLLocationDistance = 20_000

    init(style: Style = .full) {
        self.style = style
        // ダッシュボードは面積が小さいので、同じ高度だと何も読み取れない。近づける。
        cameraDistance = style == .full ? 500 : 300
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
        if let destinationAnnotation {
            mapView.removeAnnotation(destinationAnnotation)
            self.destinationAnnotation = nil
        }

        guard let route else { return }

        mapView.addOverlay(route.polyline, level: .aboveRoads)
        routeOverlay = route.polyline

        // ダッシュボードでは目的地ピンを出さない。狭い画面では読み取れないうえ、
        // ガイドが求める「clutter の少ない最小限の地図」から外れる。
        guard style == .full else { return }

        let pin = MKPointAnnotation()
        pin.coordinate = route.destination.coordinate
        pin.title = route.destination.name
        mapView.addAnnotation(pin)
        destinationAnnotation = pin
    }

    // MARK: - カメラ

    func follow(location: CLLocation) {
        guard isFollowingUser else { return }

        // 停車中は course が -1 になる。そのときは向きを変えず、地図が回るのを防ぐ。
        let heading = location.course >= 0 ? location.course : mapView.camera.heading
        let camera = MKMapCamera(lookingAtCenter: location.coordinate,
                                 fromDistance: cameraDistance,
                                 pitch: 45,
                                 heading: heading)
        mapView.setCamera(camera, animated: true)
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

    func recenter() {
        isFollowingUser = true
        if let location = LocationService.shared.location {
            follow(location: location)
        }
    }

    func zoomIn() {
        setCameraDistance(cameraDistance / 2)
    }

    func zoomOut() {
        setCameraDistance(cameraDistance * 2)
    }

    private func setCameraDistance(_ distance: CLLocationDistance) {
        cameraDistance = min(max(distance, minimumCameraDistance), maximumCameraDistance)
        if let location = LocationService.shared.location, isFollowingUser {
            follow(location: location)
        } else {
            let camera = mapView.camera
            camera.altitude = cameraDistance
            mapView.setCamera(camera, animated: true)
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
        renderer.lineWidth = style == .full ? 10 : 8
        renderer.lineCap = .round
        renderer.lineJoin = .round
        return renderer
    }
}
