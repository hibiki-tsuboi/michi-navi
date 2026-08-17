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
        coordinator.apply(contentStyle: templateApplicationScene.contentStyle)
        self.coordinator = coordinator
    }

    /// 車がトンネルや日没で昼夜を切り替えてくる。
    func contentStyleDidChange(_ contentStyle: UIUserInterfaceStyle) {
        coordinator?.apply(contentStyle: contentStyle)
    }

    /// 背面のときに出た曲がる指示のバナーを押された。CarPlay がこの画面を前面へ戻すので、
    /// こちらは中身を合わせるだけ。**押されたのがどれかは見ていない**（バナーに出るのは
    /// 常に次の指示で、選ぶ余地が無い）。
    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didSelect maneuver: CPManeuver) {
        coordinator?.bannerSelected()
    }

    /// 助言のバナー（駐車場・迂回・休憩など）を押された。**どの助言かで動きを変えない。**
    /// 受けるかどうかはバナーのボタンで決まっていて、本文を押すのは
    /// 「画面で見たい」以上の意味を持たない。
    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didSelect navigationAlert: CPNavigationAlert) {
        coordinator?.bannerSelected()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController,
                                  from window: CPWindow) {
        coordinator?.stop()
        coordinator = nil
    }
}
