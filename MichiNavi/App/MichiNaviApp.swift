import SwiftUI

@main
struct MichiNaviApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(NavigationController.shared)
        }
    }
}
