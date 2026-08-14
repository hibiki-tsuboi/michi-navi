import CarPlay

/// CarPlay Dashboard シーンの入口。Info.plist の
/// `CPTemplateApplicationDashboardSceneSessionRoleApplication` から名前で呼ばれる。
///
/// センターディスプレイ側の `CarPlaySceneDelegate` と同じ形で、
/// 接続・切断を受けるだけにして中身は coordinator に任せる。
/// ダッシュボードは CarPlay が必要と判断したときにだけ作られるため、
/// このシーンが来ないこともある。
///
/// センター側と違い、このシーンには `contentStyle` が無い。昼夜は渡される
/// `UIWindow` の trait collection がそのまま運んでくるので、こちらでは何もしない。
final class CarPlayDashboardSceneDelegate: UIResponder, CPTemplateApplicationDashboardSceneDelegate {
    private var coordinator: CarPlayDashboardCoordinator?

    func templateApplicationDashboardScene(
        _ templateApplicationDashboardScene: CPTemplateApplicationDashboardScene,
        didConnect dashboardController: CPDashboardController,
        to window: UIWindow) {
        let coordinator = CarPlayDashboardCoordinator(dashboardController: dashboardController,
                                                      window: window)
        coordinator.start()
        self.coordinator = coordinator
    }

    func templateApplicationDashboardScene(
        _ templateApplicationDashboardScene: CPTemplateApplicationDashboardScene,
        didDisconnect dashboardController: CPDashboardController,
        from window: UIWindow) {
        coordinator?.stop()
        coordinator = nil
    }
}
