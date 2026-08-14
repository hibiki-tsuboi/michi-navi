import Combine
import CoreLocation

/// 端末の位置と進行方向を配信する。iPhone 画面と CarPlay 画面の両方が
/// このひとつのインスタンスを共有するため、GPS は常に 1 本しか動かない。
@MainActor
final class LocationService: NSObject, ObservableObject {
    static let shared = LocationService()

    @Published private(set) var location: CLLocation?
    @Published private(set) var heading: CLHeading?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus

    private let manager = CLLocationManager()

    /// 案内中はバックグラウンドでも測位を続け、精度を最優先にする。
    private(set) var isNavigating = false

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
    }

    func requestAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse where isNavigating:
            // 案内を始めてから初めて「常に許可」を求める（Apple の推奨順序）
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    func startUpdating() {
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
    }

    func stopUpdating() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    /// 案内の開始・終了に合わせてバックグラウンド測位を切り替える。
    func setNavigating(_ navigating: Bool) {
        guard isNavigating != navigating else { return }
        isNavigating = navigating

        // 「常に許可」が無い状態で allowsBackgroundLocationUpdates を立てると例外になる。
        let canRunInBackground = manager.authorizationStatus == .authorizedAlways
        manager.allowsBackgroundLocationUpdates = navigating && canRunInBackground
        manager.showsBackgroundLocationIndicator = navigating

        if navigating {
            requestAuthorization()
            startUpdating()
        }
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard let newest = locations.last else { return }
            location = newest
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        MainActor.assumeIsolated {
            guard newHeading.headingAccuracy >= 0 else { return }
            heading = newHeading
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            authorizationStatus = manager.authorizationStatus
            switch manager.authorizationStatus {
            case .authorizedAlways:
                manager.allowsBackgroundLocationUpdates = isNavigating
                startUpdating()
            case .authorizedWhenInUse:
                startUpdating()
            default:
                stopUpdating()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        NSLog("[MichiNavi] 位置情報の取得に失敗: \(error.localizedDescription)")
    }
}
