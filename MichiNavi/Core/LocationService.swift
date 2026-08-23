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

    /// **求めるのは「使用中のみ」まで。**
    ///
    /// 2026-08-23 まで、案内を始めた時点で「常に許可」も求めていた。**要らなかった。**
    /// Always が要るのはアプリが動いていないときに位置で起こされたい場合
    /// （リージョン監視・大幅変更監視）で、このアプリはどちらも使っていない。
    /// 走行中の案内に必要なのは背景測位（[setNavigating]）だけで、そちらは
    /// 「使用中のみ」で立つ。要らない許可を運転中に求めない、という判断は
    /// `SpeechInput` がマイク以外を求めないのと同じ。
    func requestAuthorization() {
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
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
    ///
    /// **「常に許可」は要らない。** `allowsBackgroundLocationUpdates` が要求するのは
    /// **Info.plist の背景モード**（`UIBackgroundModes` の `location`）だけで、認可の
    /// 状態は見ていない。CoreLocation が持つ例外の文言も
    /// `Application must support the location background mode` としか言っていないし、
    /// `.authorizedWhenInUse` のまま立てられることを 26.6 で実測した。
    ///
    /// 2026-08-23 まで `.authorizedAlways` を条件にしていたので、「使用中のみ」で走ると
    /// **アプリのシーンが 1 つも前面でなくなった瞬間に測位が止まっていた**。CarPlay の
    /// 画面が出ているあいだは前面だが、運転者が別の CarPlay アプリへ切り替えれば外れる。
    /// そこから先は推測航法しか動かず、推測では到着を判定しないので**案内が凍る**。
    ///
    /// **背景モードを外さないこと。** 外すとここが例外になる（`BackgroundModeTests`）。
    func setNavigating(_ navigating: Bool) {
        guard isNavigating != navigating else { return }
        isNavigating = navigating

        manager.allowsBackgroundLocationUpdates = navigating
        manager.showsBackgroundLocationIndicator = navigating

        if navigating { startUpdating() }
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
            case .authorizedAlways, .authorizedWhenInUse:
                // **どちらでも同じ扱い。** 背景測位に必要なのは背景モードだけで、
                // 「常に許可」かどうかは効かない（[setNavigating]）。
                manager.allowsBackgroundLocationUpdates = isNavigating
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
