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
        Category(title: "ガソリン", symbol: "fuelpump.fill", pointsOfInterest: [.gasStation]),
        Category(title: "EV充電", symbol: "bolt.car.fill", pointsOfInterest: [.evCharger]),
        Category(title: "駐車場", symbol: "parkingsign", pointsOfInterest: [.parking]),
        // MapKit に SA/PA のカテゴリは無いので、休憩に使えるものを束ねて代用する。
        Category(title: "休憩", symbol: "cup.and.heat.waves.fill",
                 pointsOfInterest: [.restroom, .cafe, .gasStation]),
        Category(title: "食事", symbol: "fork.knife", pointsOfInterest: [.restaurant]),
        Category(title: "カフェ", symbol: "cup.and.saucer.fill", pointsOfInterest: [.cafe]),
        Category(title: "買い物", symbol: "cart.fill", pointsOfInterest: [.store]),
        Category(title: "ATM・銀行", symbol: "banknote", pointsOfInterest: [.atm, .bank]),
        Category(title: "病院", symbol: "cross.case.fill", pointsOfInterest: [.hospital]),
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
        guard let category = Self.categories.first(where: { $0.title == "休憩" }) else { return }
        presentResults(for: category)
    }

    // MARK: - 目的地リスト

    private func makeRootTemplate() -> CPListTemplate {
        var sections: [CPListSection] = []

        if !store.favorites.isEmpty {
            sections.append(CPListSection(items: store.favorites.map(makeItem(for:)),
                                          header: "お気に入り",
                                          sectionIndexTitle: nil))
        }

        if !store.recents.isEmpty {
            sections.append(CPListSection(items: store.recents.map(makeItem(for:)),
                                          header: "最近の目的地",
                                          sectionIndexTitle: nil))
        }

        sections.append(CPListSection(items: [categoriesItem, detourItem],
                                      header: "さがす",
                                      sectionIndexTitle: nil))

        sections.append(CPListSection(items: [avoidItem(\.avoidsTolls, title: "有料道路を避ける"),
                                              avoidItem(\.avoidsHighways, title: "高速道路を避ける"),
                                              avoidItem(\.prefersWinding, title: "曲がりくねった道を優先",
                                                        on: "優先する", off: "しない")],
                                      header: "ルートの引き方",
                                      sectionIndexTitle: nil))

        let template = CPListTemplate(title: "目的地", sections: sections)
        // キーボードが塞がれているときに検索ボタンを出すと、押しても何も起きない
        // 導線になってしまう。そのときは最初から出さない。
        if !isKeyboardLimited {
            template.trailingNavigationBarButtons = [searchButton]
        }
        return template
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
                           title: String,
                           on: String = "避ける",
                           off: String = "避けない") -> CPListItem {
        let isOn = preferences[keyPath: key]
        let item = CPListItem(text: title,
                              detailText: isOn ? on : off,
                              image: nil,
                              accessoryImage: isOn ? UIImage(systemName: "checkmark") : nil,
                              accessoryType: .none)
        item.handler = { [weak self] _, completion in
            guard let self else { return completion() }
            preferences[keyPath: key].toggle()
            // 走っている案内は引き直さない（次に計算するときから効く）ので、
            // ここで伝えておかないと「押したのに何も変わらない」と見える。
            interfaceController.popTemplate(animated: false) { [weak self] _, _ in
                self?.present()
            }
            completion()
        }
        return item
    }

    /// 寄り道をひとつ提案する。
    ///
    /// 押した先で一覧を出さず、いきなり 1 件を見せる。候補を並べると結局いつもの
    /// 選び方に戻ってしまい、乱数に任せた意味が無くなる。
    private var detourItem: CPListItem {
        let item = CPListItem(text: "寄り道してみる",
                              detailText: isNavigating ? "この先から 1 件えらぶ" : "近くから 1 件えらぶ")
        item.handler = { [weak self] _, completion in
            self?.suggestDetour()
            completion()
        }
        return item
    }

    private func suggestDetour() {
        guard let coordinate = location.location?.coordinate else {
            onError("現在地が取得できていません")
            return
        }

        Task {
            do {
                let suggestion = try await DetourSuggester.suggest(
                    near: coordinate,
                    along: navigation.currentRoute,
                    fromStepIndex: navigation.progress?.stepIndex ?? 0)

                guard let suggestion else {
                    onError("寄り道できそうな場所が見つかりませんでした")
                    return
                }
                presentDetour(suggestion)
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    private func presentDetour(_ suggestion: DetourSuggester.Suggestion) {
        let sheet = CPActionSheetTemplate(
            title: suggestion.place.name,
            message: "\(suggestion.category)・\(suggestion.place.subtitle)",
            actions: [
                CPAlertAction(title: isNavigating ? "経由地として追加" : "ここへ行く", style: .default) { [weak self] _ in
                    self?.dismissSheet()
                    self?.finish(with: self?.isNavigating == true ? .waypoint(suggestion.place)
                                                                 : .destination(suggestion.place))
                },
                CPAlertAction(title: "ほかをさがす", style: .default) { [weak self] _ in
                    self?.dismissSheet()
                    self?.suggestDetour()
                },
                CPAlertAction(title: "やめる", style: .cancel) { [weak self] _ in
                    self?.dismissSheet()
                },
            ])
        interfaceController.presentTemplate(sheet, animated: true, completion: nil)
    }

    private var categoriesItem: CPListItem {
        // accessoryType で下の階層があることを示す（ガイド p.44）。
        let item = CPListItem(text: "周辺のカテゴリから",
                              detailText: "ガソリン、駐車場、食事など",
                              image: nil,
                              accessoryImage: nil,
                              accessoryType: .disclosureIndicator)
        item.handler = { [weak self] _, completion in
            self?.presentCategories()
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
            CPAlertAction(title: "経由地として追加", style: .default) { [weak self] _ in
                self?.dismissSheet()
                self?.finish(with: .waypoint(place))
            },
            CPAlertAction(title: "目的地を変更", style: .default) { [weak self] _ in
                self?.dismissSheet()
                self?.finish(with: .destination(place))
            },
            CPAlertAction(title: "キャンセル", style: .cancel) { [weak self] _ in
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

        let template = CPGridTemplate(title: isNavigating ? "ルート沿いをさがす" : "周辺をさがす",
                                      gridButtons: buttons)
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    private func presentResults(for category: Category) {
        // 先に空のリストを出してから埋める。結果を待ってから画面を出すと、
        // 押したのに何も起きない時間ができて運転中に不安になる。
        let template = CPListTemplate(title: category.title, sections: [])
        template.emptyViewSubtitleVariants = ["探しています…"]
        interfaceController.pushTemplate(template, animated: true, completion: nil)

        Task {
            do {
                let places = try await places(for: category)
                let items = places.prefix(CPListTemplate.maximumItemCount).map(makeItem(for:))
                template.updateSections([CPListSection(items: Array(items))])
                template.emptyViewSubtitleVariants = [isNavigating
                    ? "この先には見つかりませんでした"
                    : "近くに見つかりませんでした"]
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
        CPBarButton(title: "検索") { [weak self] _ in self?.presentSearch() }
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
                    onError("場所が特定できませんでした")
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
