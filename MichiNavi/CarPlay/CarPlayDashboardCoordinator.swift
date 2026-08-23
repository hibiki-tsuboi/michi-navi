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
    private let preferences = RoutePreferences.shared
    private let search = SearchService.shared

    private var cancellables = Set<AnyCancellable>()
    /// 補給先を探している最中の仕事。連打で 2 本走らせない。
    private var searchTask: Task<Void, Never>?

    init(dashboardController: CPDashboardController, window: UIWindow) {
        self.dashboardController = dashboardController
        self.window = window
    }

    func start() {
        window.rootViewController = mapViewController
        observeState()
    }

    func stop() {
        cancellables.removeAll()
        searchTask?.cancel()
        searchTask = nil
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
        //
        // **流れてきた値をそのまま渡す。** `@Published` は `willSet` で流れるので、
        // `updateShortcuts` の中で `store.recents` を読み直すと必ず 1 つ前の値になる。
        // `DestinationStore.remember` は削除と挿入で 2 回書くため、最後の流れで読めるのは
        // 「消したあと・入れる前」の並び＝**いま案内を始めた行き先だけが落ちる**。
        // `clearRecents()` では裏返しに、消したはずの履歴からボタンを組み直してしまう
        // （`buttons.isEmpty` を通るので、そのまま残る）。
        // **どちらも流れてきた値をそのまま渡す。** `@Published` は `willSet` で流れるので、
        // sink の中で読み直すと 1 つ前の値になる（`store.recents` は削除と挿入で 2 回書くため、
        // 読み直すと「消したあと・入れる前」の並びが取れてしまう）。
        // 購読した時点で現在値が 1 回流れるので、初回の組み立てもここが兼ねる。
        Publishers.CombineLatest3(store.$recents, store.$home, preferences.$refuelKind)
            .sink { [weak self] recents, home, refuelKind in
                self?.updateShortcuts(recents: recents, home: home, refuelKind: refuelKind)
            }
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
    }

    /// ショートカットは案内していないときだけ表示される（ガイド p.54）。
    /// 押したらそのまま案内を始める。ダッシュボードを見ている人に
    /// センターディスプレイ側の確認画面を探させないため。
    ///
    /// 中身は**自宅（無ければいちばん新しい履歴）と、補給先** [refuelButton]。
    /// 履歴で 2 枠とも埋めていたのを 2026-08-23 に分けた。**案内中は CarPlay が畳む**ので、
    /// ここに置けるのは「走り出す前の 1 タップ」だけ。走行中に周辺を探す道は
    /// マイクと目的地リストのヘッダに残っている。
    ///
    /// **自宅を履歴より先に置く。** 帰り道はここからの 1 タップがいちばん短い。
    /// 履歴の先頭はたいてい自宅と重なるが、重ならないとき（出先で寄り道した直後）が
    /// **まさに帰りたい場面**なので、そこで自宅が消える並びにはしない。
    ///
    /// **空配列を代入しないこと**。CarPlay 側は「ちょうど 1 件」と「それ以外」で
    /// レイアウトを分けており、0 件は後者に落ちて先頭・末尾のボタンが nil のまま
    /// 制約の配列に入る。CarPlayTemplateUIHost が `NSArray` の生成で例外を投げて落ちる
    /// （履歴が空のまま Dashboard を繋ぐと必ず再現する）。
    /// 隠す必要があるとき（案内中）は CarPlay が自前でやってくれる。曲がり方を出すときに
    /// ショートカット欄を畳み、案内が終わると戻す。こちらから消しにいかなくてよい。
    private func updateShortcuts(recents: [Place], home: Place?, refuelKind: RoutePreferences.RefuelKind) {
        var buttons: [CPDashboardButton] = []
        if let home {
            buttons.append(CPDashboardButton(titleVariants: [DestinationStore.Pinned.home.title],
                                             // 名札だけでは「どこへ向かうのか」が分からないので、
                                             // 設定した地点を添える。目的地リストのピンと同じ形。
                                             subtitleVariants: [home.name],
                                             image: Self.pinnedImage) { [weak self] _ in
                self?.navigation.startNavigation(to: home)
            })
        } else {
            buttons += recents
                .prefix(Self.maximumButtons - 1)
                .map { place in
                    CPDashboardButton(titleVariants: [place.name],
                                      subtitleVariants: [place.subtitle],
                                      image: Self.shortcutImage) { [weak self] _ in
                        self?.navigation.startNavigation(to: place)
                    }
                }
        }
        buttons.append(refuelButton(kind: refuelKind))

        dashboardController.shortcutButtons = buttons
    }

    /// 補給先へ 1 タップで向かうショートカット。**2 枠のうち 1 つを常に使う。**
    ///
    /// **一覧を出さずに、いちばん近い 1 件へそのまま案内を始める。** ダッシュボードに
    /// テンプレートは出せないので、探した結果を選ばせようとすると**片方の画面で始めて
    /// もう片方で終わる導線**になる。履歴のボタンが「押したらそのまま案内」なのと
    /// 同じ形に揃えた。候補を並べずに 1 件へ決める作りは、声の入口
    /// （`CarPlayVoiceControl`）と駐車場の提案がすでにそうしている。
    ///
    /// **カテゴリは `RoutePreferences.refuelKind` に従う**（ガソリン／充電）。
    /// ダッシュボード専用の設定を足すと、決める場所が増えるわりに中身は同じになる。
    ///
    /// **これが常に 1 件あるおかげで `shortcutButtons` が 0 件になりえない。**
    /// 空配列は CarPlay ホストを落とす（履歴が空のまま繋ぐと必ず再現していた）。
    private func refuelButton(kind: RoutePreferences.RefuelKind) -> CPDashboardButton {
        CPDashboardButton(titleVariants: [kind.title],
                          // **確認を挟まないことを先に言っておく。** 押した瞬間に
                          // 案内が始まるので、何が起きるか読めないまま押させない。
                          subtitleVariants: [String(localized: "いちばん近い場所へ")],
                          image: Self.refuelImage(for: kind)) { [weak self] _ in
            self?.startRefuelNavigation(kind: kind)
        }
    }

    /// 探して、いちばん近い 1 件へ案内を始める。
    ///
    /// **失敗は `NavigationController.lastError` に載せる。** ダッシュボードには何も
    /// 出せないので、黙って落とすと「押しても何も起きないボタン」になる。あちらへ載せると
    /// センターディスプレイがアラートを出すので、見に行ったときに理由が残っている。
    /// 経路計算そのものの失敗は `startNavigation(to:)` が同じ口に載せる。
    private func startRefuelNavigation(kind: RoutePreferences.RefuelKind) {
        guard let coordinate = location.location?.coordinate else {
            // 文言は経路計算のときと同じものを使う。同じ事情なので言い方を分けない。
            navigation.report(error: NavigationError.noCurrentLocation.localizedDescription)
            return
        }

        searchTask?.cancel()
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let places = try await search.nearby(pointsOfInterest: kind.pointsOfInterest,
                                                     around: coordinate)
                guard !Task.isCancelled else { return }
                guard let nearest = places.first else {
                    navigation.report(error: String(localized: "近くに見つかりませんでした"))
                    return
                }
                navigation.startNavigation(to: nearest)
            } catch {
                guard !Task.isCancelled else { return }
                navigation.report(error: error.localizedDescription)
            }
        }
    }

    private static let pinnedImage: UIImage = {
        let configuration = UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
        return UIImage(systemName: DestinationStore.Pinned.home.symbol, withConfiguration: configuration)?
            .withRenderingMode(.alwaysTemplate) ?? UIImage()
    }()

    private static func refuelImage(for kind: RoutePreferences.RefuelKind) -> UIImage {
        let configuration = UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
        let name = kind == .gasStation ? "fuelpump.fill" : "bolt.car.fill"
        return UIImage(systemName: name, withConfiguration: configuration)?
            .withRenderingMode(.alwaysTemplate) ?? UIImage()
    }

    private static let shortcutImage: UIImage = {
        let configuration = UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
        return UIImage(systemName: "arrow.turn.up.right", withConfiguration: configuration)?
            .withRenderingMode(.alwaysTemplate) ?? UIImage()
    }()
}
