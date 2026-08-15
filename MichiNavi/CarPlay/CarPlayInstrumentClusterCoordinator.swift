import CarPlay
import Combine

/// メーター内（インストルメントクラスタ）に出す 3 つ目の地図。
///
/// 運転席の速度計まわりに地図を描く。対応した車でだけシーンが作られるので、
/// **来ない前提**で書く。Dashboard と同じく `NavigationController` を購読するだけで、
/// 案内ロジックは持たない。次の曲がり方や残り時間は、`CPMapTemplate` と
/// `CPNavigationSession` を使っていれば CarPlay が自前で描く。
///
/// ガイド p.55 がこの画面に課している条件:
///   - 余計なものを描かない最小限の地図（`.cluster` スタイルがこれを担う）
///   - 全体表示ではなく、これから走る先を詳しく（常に自車追従のままにする）
///   - **進行方向を必ず上にする**（向きの設定に従わない）
///
/// Dashboard との違いは、窓が `CPInstrumentClusterController` 経由で遅れて来ること。
/// シーンが繋がった時点ではまだ描けないので、窓が来てから購読を始める。
@MainActor
final class CarPlayInstrumentClusterCoordinator: NSObject {
    private let controller: CPInstrumentClusterController
    private let mapViewController = CarPlayMapViewController(style: .cluster)

    private let navigation = NavigationController.shared
    private let location = LocationService.shared

    private var cancellables = Set<AnyCancellable>()

    init(controller: CPInstrumentClusterController) {
        self.controller = controller
        super.init()
        controller.delegate = self
        // 案内していないときにメーター内へ出る文言。
        controller.inactiveDescriptionVariants = ["MichiNavi で目的地を選んでください", "MichiNavi"]
    }

    func stop() {
        cancellables.removeAll()
        controller.delegate = nil
    }

    /// 車から渡される昼夜の指定を地図へ流す。Dashboard と違い、
    /// このシーンには `contentStyle` があるのでセンターディスプレイと同じ扱いになる。
    func apply(contentStyle: UIUserInterfaceStyle) {
        mapViewController.apply(contentStyle: contentStyle)
    }

    private func start(in window: UIWindow) {
        window.rootViewController = mapViewController
        mapViewController.setCompassVisible(controller.compassSetting == .enabled)
        observeState()
    }

    private func observeState() {
        location.$location
            .compactMap { $0 }
            .sink { [weak self] in self?.mapViewController.follow(location: $0) }
            .store(in: &cancellables)

        navigation.$phase
            .sink { [weak self] in self?.apply(phase: $0) }
            .store(in: &cancellables)
    }

    /// 全体表示には切り替えない。ガイドが「これから走る先を詳しく」と求めているため、
    /// 提示中も案内中も自車のまわりを見せ続ける。
    private func apply(phase: NavigationController.Phase) {
        switch phase {
        case .idle, .calculating:
            mapViewController.show(route: nil)
        case let .previewing(routes):
            mapViewController.show(route: routes.first)
        case let .navigating(route):
            mapViewController.show(route: route)
        }
        mapViewController.recenter()
    }
}

// MARK: - CPInstrumentClusterControllerDelegate

/// この protocol には CarPlay のテンプレート用アクター注釈が付いていない（他の
/// CarPlay の delegate とはここが違う）。既定で全部が MainActor のこのプロジェクトでは
/// そのままでは適合できないので、`LocationService` などと同じく
/// `nonisolated` + `MainActor.assumeIsolated` で受ける。CarPlay はメインスレッドから呼ぶ。
extension CarPlayInstrumentClusterCoordinator: CPInstrumentClusterControllerDelegate {
    nonisolated func instrumentClusterControllerDidConnect(_ instrumentClusterWindow: UIWindow) {
        MainActor.assumeIsolated { start(in: instrumentClusterWindow) }
    }

    // 接続側は Swift 側で ...DidConnect(_:) に短縮されるが、切断側は
    // ...DidDisconnectWindow(_:) のまま。左右で名前が揃っていないのは Swift の
    // 取り込み規則によるもので、こちらの書き間違いではない。
    nonisolated func instrumentClusterControllerDidDisconnectWindow(_ instrumentClusterWindow: UIWindow) {
        MainActor.assumeIsolated { cancellables.removeAll() }
    }

    /// メーター内はタッチできないので、ズームは車のボタンやノブから来る。
    nonisolated func instrumentClusterControllerDidZoom(in instrumentClusterController: CPInstrumentClusterController) {
        MainActor.assumeIsolated { mapViewController.zoomIn() }
    }

    nonisolated func instrumentClusterControllerDidZoomOut(_ instrumentClusterController: CPInstrumentClusterController) {
        MainActor.assumeIsolated { mapViewController.zoomOut() }
    }

    /// 方位磁針を出してよいかは車が決める。進行方向を上に固定している画面なので、
    /// 出せるなら出したほうが北がどちらか分かる。
    nonisolated func instrumentClusterController(_ instrumentClusterController: CPInstrumentClusterController,
                                                 didChangeCompassSetting compassSetting: CPInstrumentClusterSetting) {
        MainActor.assumeIsolated { mapViewController.setCompassVisible(compassSetting == .enabled) }
    }

    /// 速度制限は描いていない。MapKit が制限速度を返さず、外部依存を足さない限り
    /// 出せるデータが無いため、車から可否を言われても行うことがない。
    nonisolated func instrumentClusterController(_ instrumentClusterController: CPInstrumentClusterController,
                                                 didChangeSpeedLimitSetting speedLimitSetting: CPInstrumentClusterSetting) {}
}
