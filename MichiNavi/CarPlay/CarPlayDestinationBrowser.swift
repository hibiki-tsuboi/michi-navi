import CarPlay
import MapKit

/// CarPlay で目的地を選ぶ画面群。
///
/// 多くの車では走行中にキーボードが塞がれる。そのため検索ではなく、
/// お気に入り・履歴・周辺カテゴリを主役に置く。CarPlay ガイドラインが求める
/// 「すべての操作が iPhone を触らずに完結すること」はここで満たしている。
///
/// 階層は 目的地リスト → カテゴリ → 検索結果 の 3 段まで。
/// ナビアプリの上限は 5 段（ガイド p.14）なので収まっている。
@MainActor
final class CarPlayDestinationBrowser: NSObject {
    /// カテゴリ 1 つぶん。CarPlay のグリッドは 8 個までしか置けない。
    struct Category {
        let title: String
        let symbol: String
        let pointsOfInterest: [MKPointOfInterestCategory]
    }

    static let categories: [Category] = [
        Category(title: String(localized: "ガソリン"), symbol: "fuelpump.fill", pointsOfInterest: [.gasStation]),
        Category(title: String(localized: "EV充電"), symbol: "bolt.car.fill", pointsOfInterest: [.evCharger]),
        Category(title: String(localized: "駐車場"), symbol: "parkingsign", pointsOfInterest: [.parking]),
        // MapKit に SA/PA のカテゴリは無いので、休憩に使えるものを束ねて代用する。
        Category(title: String(localized: "休憩"), symbol: "cup.and.heat.waves.fill",
                 pointsOfInterest: [.restroom, .cafe, .gasStation]),
        Category(title: String(localized: "食事"), symbol: "fork.knife", pointsOfInterest: [.restaurant]),
        Category(title: String(localized: "カフェ"), symbol: "cup.and.saucer.fill", pointsOfInterest: [.cafe]),
        Category(title: String(localized: "買い物"), symbol: "cart.fill", pointsOfInterest: [.store]),
        Category(title: String(localized: "ATM・銀行"), symbol: "banknote", pointsOfInterest: [.atm, .bank]),
        Category(title: String(localized: "病院"), symbol: "cross.case.fill", pointsOfInterest: [.hospital]),
    ]

    /// 選んだ地点をどう扱うか。
    enum Choice {
        /// 目的地にする。案内中なら行き先を差し替える。
        case destination(Place)
        /// 立ち寄り先として、いまの経路に挟む。
        case waypoint(Place)
    }

    private let interfaceController: CPInterfaceController
    private let sessionConfiguration: CPSessionConfiguration
    private let onSelect: (Choice) -> Void
    private let onError: (String) -> Void

    private let search = SearchService.shared
    private let store = DestinationStore.shared
    private let location = LocationService.shared
    private let navigation = NavigationController.shared
    private let preferences = RoutePreferences.shared

    init(interfaceController: CPInterfaceController,
         sessionConfiguration: CPSessionConfiguration,
         onSelect: @escaping (Choice) -> Void,
         onError: @escaping (String) -> Void) {
        self.interfaceController = interfaceController
        self.sessionConfiguration = sessionConfiguration
        self.onSelect = onSelect
        self.onError = onError
        super.init()
    }

    /// 目的地リストを開く。開くたびに作り直すので履歴は常に最新になる。
    func present() {
        interfaceController.pushTemplate(makeRootTemplate(), animated: true, completion: nil)
    }

    /// 休憩できる場所を直接開く。休憩の催促から呼ばれる。
    /// 目的地リストを経由させないのは、押した先が 3 階層先だと運転中に辿れないため。
    func presentRestStops() {
        guard let category = Self.categories.first(where: { $0.title == String(localized: "休憩") }) else { return }
        presentResults(for: category)
    }

    // MARK: - 目的地リスト

    private func makeRootTemplate() -> CPListTemplate {
        var sections: [CPListSection] = []

        // **いちばん上に置く。** 走行中に辿れる段数は限られるので、押される回数が
        // 多い順に並べる。設定していないものは出さない（CarPlay からは設定できず、
        // 押しても何も起きない行になるため。理由は `DestinationStore.set(_:as:)`）。
        let pinned = DestinationStore.Pinned.allCases.compactMap { kind in
            store.place(kind).map { makeItem(for: $0, titled: kind.title) }
        }
        if !pinned.isEmpty {
            sections.append(CPListSection(items: pinned,
                                          header: String(localized: "よく行く場所"),
                                          sectionIndexTitle: nil))
        }

        // **ピンのすぐ下に置く。** ピンの 2 枠に入らないが決まった時間に行く場所
        // （送り迎え・買い物）を、走行中でも届く高さへ引き上げる。
        // 順番を入れ替えるのではなく別の節にするのは、なぜ並びが変わったのかを
        // 見て分かるようにするため。
        let frequent = store.frequentDestinations()
        if !frequent.isEmpty {
            sections.append(CPListSection(items: frequent.map(makeItem(for:)),
                                          header: String(localized: "この時間の行き先"),
                                          sectionIndexTitle: nil))
        }

        if !store.favorites.isEmpty {
            sections.append(CPListSection(items: store.favorites.map(makeItem(for:)),
                                          header: String(localized: "お気に入り"),
                                          sectionIndexTitle: nil))
        }

        // 引き上げたぶんは履歴から抜く。同じ行が 2 か所に出ると、どちらを押しても
        // 同じだと分かるまで一瞬迷う。
        let remaining = store.recents.filter { !frequent.contains($0) }
        if !remaining.isEmpty {
            sections.append(CPListSection(items: remaining.map(makeItem(for:)),
                                          header: String(localized: "最近の目的地"),
                                          sectionIndexTitle: nil))
        }

        let template = CPListTemplate(title: String(localized: "目的地"), sections: sections)
        template.headerGridButtons = searchGridButtons
        // キーボードが塞がれているときに検索ボタンを出すと、押しても何も起きない
        // 導線になってしまう。そのときは最初から出さない。
        if !isKeyboardLimited {
            template.trailingNavigationBarButtons = [searchButton]
        }
        return template
    }

    /// リストのいちばん上に出す「さがす」（iOS 26.0 の `headerGridButtons`）。
    ///
    /// **リストの底からヘッダへ引き上げたもの。** 行き先の並びは押される回数の多い順に
    /// 決まっていて（ピン → この時間 → お気に入り → 履歴）、探す手段はそのさらに下に
    /// しか置けなかった。**走行中にスクロールして辿る場所ではない**ので、行数を持たない
    /// ヘッダへ出す。行き先の並びはそのまま動かさずに済む。
    ///
    /// **ルートの引き方も同じ理由でここへ引き上げた**（2026-08-23）。それまでは行き先の
    /// あとの最後の節にあったが、上にはピン 2 件・この時間の行き先・お気に入り
    /// （上限なし）・履歴（上限 20 件）が積まれるので、**30 行送った先**になりうる。
    /// しかも**設定は目的地を選ぶ手前で効く**もの（変えても走っている案内は引き直さず、
    /// 次の計算から効く）なのに、目的地より下にあった。行き先の並びは動かさずに済む。
    ///
    /// **空配列を代入しない。** Dashboard の `shortcutButtons` が 0 件で落ちる前例が
    /// あるので、0 件になりうる作りにしない（ここは常に 2 件）。足すときは
    /// `maximumHeaderGridButtonCount` が上限。
    private var searchGridButtons: [CPGridButton] {
        [
            CPGridButton(titleVariants: [isNavigating ? String(localized: "ルート沿いをさがす")
                                                      : String(localized: "周辺をさがす"),
                                         String(localized: "さがす")],
                         image: Self.gridImage(named: "location.magnifyingglass")) { [weak self] _ in
                self?.presentCategories()
            },
            // アイコンは虫めがねと紛れないもの。分かれ道の形にしてある
            // （歯車にすると、この 2 つ以外の設定もあると読める）。
            CPGridButton(titleVariants: [String(localized: "ルートの引き方")],
                         image: Self.gridImage(named: "arrow.triangle.branch")) { [weak self] _ in
                self?.presentRoutePreferences()
            },
        ]
    }

    // MARK: - ルートの引き方

    /// 有料道路・高速の回避だけの小さなリスト。
    ///
    /// **切り替えても目的地リストへ戻さない**（この画面を出し直す）。2 つとも変えたい
    /// ことがあるので、1 つ触るたびに上の階層へ落とすと入り直しになる。作り直しているのは
    /// `CPListItem` を後から差し替えるより素直なため。ここは走行中に何度も触る場所では
    /// ないので、作り直しの重さは問題にならない。
    private func presentRoutePreferences() {
        let section = CPListSection(items: [avoidItem(\.avoidsTolls, title: String(localized: "有料道路を避ける")),
                                            avoidItem(\.avoidsHighways, title: String(localized: "高速道路を避ける"))])
        let template = CPListTemplate(title: String(localized: "ルートの引き方"), sections: [section])
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    /// `titled` を渡すと、地点の名前ではなくその名札を主役にする（「自宅」＋ 地点名）。
    /// 走行中に読むのは名札のほうで、どこを指しているかは確認のために添えるだけ。
    private func makeItem(for place: Place, titled title: String? = nil) -> CPListItem {
        guard let title else { return makeItem(for: place) }
        let item = CPListItem(text: title, detailText: place.name)
        item.handler = { [weak self] _, completion in
            self?.choose(place)
            completion()
        }
        return item
    }

    private func makeItem(for place: Place) -> CPListItem {
        let item = CPListItem(text: place.name, detailText: place.subtitle)
        item.handler = { [weak self] _, completion in
            self?.choose(place)
            completion()
        }
        return item
    }

    /// 入り／切りの 1 行。**CarPlay のリストにスイッチは無い**ので、状態は
    /// チェックの有無で示し、押すたびに裏返す。
    ///
    /// 押した後にリストを作り直しているのは、`CPListItem` を後から差し替えるより
    /// 素直なため。ここは走行中に何度も触る場所ではないので、作り直しの重さは問題にならない。
    private func avoidItem(_ key: ReferenceWritableKeyPath<RoutePreferences, Bool>,
                           title: String) -> CPListItem {
        let isOn = preferences[keyPath: key]
        let item = CPListItem(text: title,
                              detailText: isOn ? String(localized: "避ける") : String(localized: "避けない"),
                              image: nil,
                              accessoryImage: isOn ? UIImage(systemName: "checkmark") : nil,
                              accessoryType: .none)
        item.handler = { [weak self] _, completion in
            guard let self else { return completion() }
            preferences[keyPath: key].toggle()
            // 走っている案内は引き直さない（次に計算するときから効く）ので、
            // チェックの付き外しだけが押した手応えになる。**戻す先はこの画面**。
            interfaceController.popTemplate(animated: false) { [weak self] _, _ in
                self?.presentRoutePreferences()
            }
            completion()
        }
        return item
    }

    /// 案内していなければそのまま目的地にする。
    ///
    /// 案内中は 1 度だけ聞く。「途中で寄りたい」のか「行き先ごと変えたい」のかは
    /// 取り違えたときの影響が大きく、走行中に気づいて戻すのは難しい。
    private func choose(_ place: Place) {
        guard isNavigating else {
            finish(with: .destination(place))
            return
        }

        let sheet = CPActionSheetTemplate(title: place.name, message: nil, actions: [
            CPAlertAction(title: String(localized: "経由地として追加"), style: .default) { [weak self] _ in
                self?.dismissSheet()
                self?.finish(with: .waypoint(place))
            },
            CPAlertAction(title: String(localized: "目的地を変更"), style: .default) { [weak self] _ in
                self?.dismissSheet()
                self?.finish(with: .destination(place))
            },
            CPAlertAction(title: String(localized: "キャンセル"), style: .cancel) { [weak self] _ in
                self?.dismissSheet()
            },
        ])
        interfaceController.presentTemplate(sheet, animated: true, completion: nil)
    }

    private func dismissSheet() {
        interfaceController.dismissTemplate(animated: true, completion: nil)
    }

    private func finish(with choice: Choice) {
        interfaceController.popToRootTemplate(animated: true, completion: nil)
        onSelect(choice)
    }

    // MARK: - カテゴリ

    private func presentCategories() {
        let buttons = Self.categories.map { category in
            CPGridButton(titleVariants: [category.title],
                         image: Self.gridImage(named: category.symbol)) { [weak self] _ in
                self?.presentResults(for: category)
            }
        }

        let template = CPGridTemplate(title: isNavigating ? String(localized: "ルート沿いをさがす") : String(localized: "周辺をさがす"),
                                      gridButtons: buttons)
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    private func presentResults(for category: Category) {
        // 先に空のリストを出してから埋める。結果を待ってから画面を出すと、
        // 押したのに何も起きない時間ができて運転中に不安になる。
        let template = CPListTemplate(title: category.title, sections: [])
        template.emptyViewSubtitleVariants = [String(localized: "探しています…")]
        interfaceController.pushTemplate(template, animated: true, completion: nil)

        Task {
            do {
                let places = try await places(for: category)
                let items = places.prefix(CPListTemplate.maximumItemCount).map(makeItem(for:))
                template.updateSections([CPListSection(items: Array(items))])
                template.emptyViewSubtitleVariants = [isNavigating
                    ? String(localized: "この先には見つかりませんでした")
                    : String(localized: "近くに見つかりませんでした")]
            } catch {
                template.emptyViewSubtitleVariants = [error.localizedDescription]
            }
        }
    }

    /// 案内中は経路の先を、そうでなければ現在地のまわりを探す。
    /// 走行中に「近いが後ろにある店」を出しても、運転者には選びようがない。
    private func places(for category: Category) async throws -> [Place] {
        if let route = navigation.currentRoute {
            let stepIndex = navigation.progress?.stepIndex ?? 0
            return try await search.alongRoute(
                pointsOfInterest: category.pointsOfInterest,
                coordinates: route.remainingCoordinates(from: stepIndex))
        }

        guard let coordinate = location.location?.coordinate else {
            throw NavigationError.noCurrentLocation
        }
        return try await search.nearby(pointsOfInterest: category.pointsOfInterest, around: coordinate)
    }

    private var isNavigating: Bool {
        navigation.currentRoute != nil
    }

    /// グリッドアイコンの上限は 40pt（ガイド p.28）。
    /// SF Symbols を使うと light / dark 両方に自動で追従する。
    private static func gridImage(named symbol: String) -> UIImage {
        let configuration = UIImage.SymbolConfiguration(pointSize: 36, weight: .regular)
        return UIImage(systemName: symbol, withConfiguration: configuration)?
            .withRenderingMode(.alwaysTemplate) ?? UIImage()
    }

    // MARK: - 検索

    private var searchButton: CPBarButton {
        CPBarButton(title: String(localized: "検索")) { [weak self] _ in self?.presentSearch() }
    }

    private func presentSearch() {
        let template = CPSearchTemplate()
        template.delegate = self
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    private var isKeyboardLimited: Bool {
        sessionConfiguration.limitedUserInterfaces.contains(.keyboard)
    }

    /// 現在地まわりを検索範囲にすると、同名チェーン店で近い順に出る。
    private var currentRegion: MKCoordinateRegion? {
        guard let coordinate = location.location?.coordinate else { return nil }
        return MKCoordinateRegion(center: coordinate, latitudinalMeters: 20_000, longitudinalMeters: 20_000)
    }
}

// MARK: - CPSearchTemplateDelegate

extension CarPlayDestinationBrowser: CPSearchTemplateDelegate {
    func searchTemplate(_ searchTemplate: CPSearchTemplate,
                        updatedSearchText searchText: String,
                        completionHandler: @escaping ([CPListItem]) -> Void) {
        search.suggest(searchText, near: currentRegion) { completions in
            // CarPlay の検索結果は運転中の安全のため件数が制限される。
            let items = completions.prefix(12).map { completion -> CPListItem in
                let item = CPListItem(text: completion.title, detailText: completion.subtitle)
                item.userInfo = completion
                return item
            }
            completionHandler(Array(items))
        }
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate,
                        selectedResult item: CPListItem,
                        completionHandler: @escaping () -> Void) {
        guard let completion = item.userInfo as? MKLocalSearchCompletion else {
            completionHandler()
            return
        }

        Task {
            defer { completionHandler() }
            do {
                let places = try await search.resolve(completion)
                guard let place = places.first else {
                    onError(String(localized: "場所が特定できませんでした"))
                    return
                }
                choose(place)
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    func searchTemplateSearchButtonPressed(_ searchTemplate: CPSearchTemplate) {
        interfaceController.popToRootTemplate(animated: true, completion: nil)
    }
}
