import CarPlay

/// メーター内シーンの入口。Info.plist の
/// `CPTemplateApplicationInstrumentClusterSceneSessionRoleApplication` から名前で呼ばれる。
///
/// 他の 2 つのシーンと同じく、接続・切断を受けるだけにして中身は coordinator に任せる。
/// このシーンは対応した車でしか作られないので、来ないことのほうが多い。
///
/// Dashboard と違い、こちらには `contentStyle` があるのでセンターディスプレイと同じく
/// 昼夜を明示的に流す。窓は `CPInstrumentClusterController` の delegate 経由で
/// 遅れて渡ってくるため、ここでは受け取らない。
final class CarPlayInstrumentClusterSceneDelegate: UIResponder,
                                                   CPTemplateApplicationInstrumentClusterSceneDelegate {
    private var coordinator: CarPlayInstrumentClusterCoordinator?

    func templateApplicationInstrumentClusterScene(
        _ templateApplicationInstrumentClusterScene: CPTemplateApplicationInstrumentClusterScene,
        didConnect instrumentClusterController: CPInstrumentClusterController) {
        let coordinator = CarPlayInstrumentClusterCoordinator(controller: instrumentClusterController)
        coordinator.apply(contentStyle: templateApplicationInstrumentClusterScene.contentStyle)
        self.coordinator = coordinator
    }

    func templateApplicationInstrumentClusterScene(
        _ templateApplicationInstrumentClusterScene: CPTemplateApplicationInstrumentClusterScene,
        didDisconnectInstrumentClusterController instrumentClusterController: CPInstrumentClusterController) {
        coordinator?.stop()
        coordinator = nil
    }

    func contentStyleDidChange(_ contentStyle: UIUserInterfaceStyle) {
        coordinator?.apply(contentStyle: contentStyle)
    }
}
