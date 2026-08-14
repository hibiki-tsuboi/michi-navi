import CarPlay

/// CarPlay 画面のライフサイクル入口。Info.plist の
/// `CPTemplateApplicationSceneSessionRoleApplication` から名前で呼ばれる。
///
/// ここは接続・切断を受けるだけにして、中身は `CarPlayCoordinator` に任せる。
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var coordinator: CarPlayCoordinator?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController,
                                  to window: CPWindow) {
        let coordinator = CarPlayCoordinator(interfaceController: interfaceController, window: window)
        coordinator.start()
        self.coordinator = coordinator
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController,
                                  from window: CPWindow) {
        coordinator?.stop()
        coordinator = nil
    }
}
