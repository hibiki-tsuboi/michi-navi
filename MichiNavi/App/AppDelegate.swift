import UIKit

/// CarPlay 画面の生成は Info.plist のシーンマニフェストが担当するので、
/// ここではシーン設定を書かない。書くとマニフェストより優先されてしまい、
/// SwiftUI 側の `WindowGroup` が作られなくなる。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        LocationService.shared.requestAuthorization()
        LocationService.shared.startUpdating()
        // iPhone 画面と CarPlay 画面のどちらから案内を始めても読み上げるよう、
        // シーンではなくアプリの起動時に購読を始める。
        VoiceGuidance.shared.start()
        // 連続運転の数え上げも同じ理由でここから。案内をまたいで積み上げるので、
        // シーンの寿命ではなくアプリの寿命に合わせる必要がある。
        RestReminder.shared.start()
        RangeAdvisor.shared.start()
        RouteWeather.shared.start()
        ParkingAdvisor.shared.start()
        return true
    }
}
