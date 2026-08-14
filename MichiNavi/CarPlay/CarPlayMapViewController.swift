import CarPlay
import MapKit

/// CarPlay の `CPWindow` に敷く地図。
///
/// テンプレート（上部バー・案内カード・下部ボタン）は地図の上に重なって描かれる。
/// そのぶんは `view.safeAreaInsets` に入ってくるので、中心合わせや全体表示では
/// 必ずこれを差し引く。差し引かないと自車位置が案内カードの裏に隠れる。
final class CarPlayMapViewController: UIViewController {
    private let mapView = MKMapView()
    private var routeOverlay: MKPolyline?
    private var destinationAnnotation: MKPointAnnotation?

    /// 自車を追従する（案内中）か、地図を自由に見せる（パン中・全体表示中）か。
    private(set) var isFollowingUser = true

    /// 追従時のカメラ高度。ズームボタンで上下する。
    private var cameraDistance: CLLocationDistance = 500
    private let minimumCameraDistance: CLLocationDistance = 200
    private let maximumCameraDistance: CLLocationDistance = 20_000

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

    /// パン操作。CarPlay はタッチではなくノブ／トラックパッドの方向入力で来る。
    func pan(by translation: CGPoint) {
        isFollowingUser = false
        let center = mapView.convert(mapView.center, toCoordinateFrom: mapView)
        var point = mapView.convert(center, toPointTo: mapView)
        point.x -= translation.x
        point.y -= translation.y
        mapView.setCenter(mapView.convert(point, toCoordinateFrom: mapView), animated: true)
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
        renderer.lineWidth = 10
        renderer.lineCap = .round
        renderer.lineJoin = .round
        return renderer
    }
}
