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
        Category(title: "食事", symbol: "fork.knife", pointsOfInterest: [.restaurant]),
        Category(title: "カフェ", symbol: "cup.and.saucer.fill", pointsOfInterest: [.cafe]),
        Category(title: "買い物", symbol: "cart.fill", pointsOfInterest: [.store]),
        Category(title: "ATM・銀行", symbol: "banknote", pointsOfInterest: [.atm, .bank]),
        Category(title: "病院", symbol: "cross.case.fill", pointsOfInterest: [.hospital]),
    ]

    private let interfaceController: CPInterfaceController
    private let sessionConfiguration: CPSessionConfiguration
    private let onSelect: (Place) -> Void
    private let onError: (String) -> Void

    private let search = SearchService.shared
    private let store = DestinationStore.shared
    private let location = LocationService.shared

    init(interfaceController: CPInterfaceController,
         sessionConfiguration: CPSessionConfiguration,
         onSelect: @escaping (Place) -> Void,
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

        sections.append(CPListSection(items: [categoriesItem],
                                      header: "さがす",
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

    private func choose(_ place: Place) {
        interfaceController.popToRootTemplate(animated: true, completion: nil)
        onSelect(place)
    }

    // MARK: - カテゴリ

    private func presentCategories() {
        let buttons = Self.categories.map { category in
            CPGridButton(titleVariants: [category.title],
                         image: Self.gridImage(named: category.symbol)) { [weak self] _ in
                self?.presentResults(for: category)
            }
        }

        let template = CPGridTemplate(title: "周辺をさがす", gridButtons: buttons)
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    private func presentResults(for category: Category) {
        guard let coordinate = location.location?.coordinate else {
            onError("現在地が取得できていません")
            return
        }

        // 先に空のリストを出してから埋める。結果を待ってから画面を出すと、
        // 押したのに何も起きない時間ができて運転中に不安になる。
        let template = CPListTemplate(title: category.title, sections: [])
        template.emptyViewSubtitleVariants = ["探しています…"]
        interfaceController.pushTemplate(template, animated: true, completion: nil)

        Task {
            do {
                let places = try await search.nearby(pointsOfInterest: category.pointsOfInterest,
                                                     around: coordinate)
                let items = places.prefix(CPListTemplate.maximumItemCount).map(makeItem(for:))
                template.updateSections([CPListSection(items: Array(items))])
                template.emptyViewSubtitleVariants = ["近くに見つかりませんでした"]
            } catch {
                template.emptyViewSubtitleVariants = [error.localizedDescription]
            }
        }
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
