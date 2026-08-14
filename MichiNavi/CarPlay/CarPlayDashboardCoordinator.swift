import CarPlay
import Combine

/// CarPlay Dashboard に出す 2 つ目の地図。
///
/// 自アプリが前面でなくても、地図と次の指示が見えるようにするためのもの。
/// 案内カードの中身（次の曲がり方や残り時間）は、`CPMapTemplate` と
/// `CPNavigationSession` を使っていれば CarPlay が自動で描く（ガイド p.54）。
/// つまりここが受け持つのは地図の描画と、案内していないときのボタンだけ。
///
/// `CarPlayCoordinator` と同じく `NavigationController` を購読するだけで、
/// 案内ロジックは持たない。
@MainActor
final class CarPlayDashboardCoordinator {
    /// ダッシュボードに置けるボタンは 2 つまで（ガイド p.54）。
    private static let maximumButtons = 2

    private let dashboardController: CPDashboardController
    private let window: UIWindow
    private let mapViewController = CarPlayMapViewController(style: .compact)

    private let navigation = NavigationController.shared
    private let location = LocationService.shared
    private let store = DestinationStore.shared

    private var cancellables = Set<AnyCancellable>()

    init(dashboardController: CPDashboardController, window: UIWindow) {
        self.dashboardController = dashboardController
        self.window = window
    }

    func start() {
        window.rootViewController = mapViewController
        observeState()
        updateShortcuts()
    }

    func stop() {
        cancellables.removeAll()
        dashboardController.shortcutButtons = []
    }

    private func observeState() {
        location.$location
            .compactMap { $0 }
            .sink { [weak self] in self?.mapViewController.follow(location: $0) }
            .store(in: &cancellables)

        navigation.$phase
            .sink { [weak self] in self?.apply(phase: $0) }
            .store(in: &cancellables)

        // 履歴が増えたらショートカットも入れ替える。
        store.$recents
            .sink { [weak self] _ in self?.updateShortcuts() }
            .store(in: &cancellables)
    }

    private func apply(phase: NavigationController.Phase) {
        switch phase {
        case .idle, .calculating:
            mapViewController.show(route: nil)
            mapViewController.recenter()
        case let .previewing(routes):
            mapViewController.show(route: routes.first)
        case let .navigating(route):
            mapViewController.show(route: route)
            mapViewController.recenter()
        }
        updateShortcuts()
    }

    /// ショートカットは案内していないときだけ表示される（ガイド p.54）。
    /// 押したらそのまま案内を始める。ダッシュボードを見ている人に
    /// センターディスプレイ側の確認画面を探させないため。
    private func updateShortcuts() {
        guard case .idle = navigation.phase else {
            dashboardController.shortcutButtons = []
            return
        }

        dashboardController.shortcutButtons = store.recents
            .prefix(Self.maximumButtons)
            .map { place in
                CPDashboardButton(titleVariants: [place.name],
                                  subtitleVariants: [place.subtitle],
                                  image: Self.shortcutImage) { [weak self] _ in
                    self?.navigation.startNavigation(to: place)
                }
            }
    }

    private static let shortcutImage: UIImage = {
        let configuration = UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
        return UIImage(systemName: "arrow.turn.up.right", withConfiguration: configuration)?
            .withRenderingMode(.alwaysTemplate) ?? UIImage()
    }()
}
