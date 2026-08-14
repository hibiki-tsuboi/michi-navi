import CarPlay
import Combine
import MapKit

/// CarPlay 画面の司令塔。
///
/// 役割は 2 つだけに絞ってある:
///   1. `NavigationController` の状態変化を CarPlay テンプレートに反映する
///   2. CarPlay 上の操作を `NavigationController` への要求に変換する
///
/// 案内ロジックそのものは持たない。だから iPhone 側から案内を始めても、
/// CarPlay 側から始めても、まったく同じ状態遷移になる。
@MainActor
final class CarPlayCoordinator: NSObject {
    private let interfaceController: CPInterfaceController
    private let window: CPWindow
    private let mapViewController = CarPlayMapViewController()
    private let mapTemplate = CPMapTemplate()

    private let navigation = NavigationController.shared
    private let location = LocationService.shared

    /// 車が今どこまで UI を制限しているか（走行中のキーボード封じなど）を教えてくれる。
    private var sessionConfiguration: CPSessionConfiguration?
    private var destinations: CarPlayDestinationBrowser?

    private var navigationSession: CPNavigationSession?
    private var currentTrip: CPTrip?
    private var activeManeuver: CPManeuver?
    /// `pauseTrip` を出したかどうか。自分で止めたときだけ再開する。
    /// 止めていないのに `resumeTrip` を投げると CarPlay 側の状態と食い違う。
    private var isTripPaused = false
    /// ドラッグ中に受け取った累積移動量。差分を出すために覚えておく。
    private var lastPanTranslation: CGPoint = .zero
    private var cancellables = Set<AnyCancellable>()

    init(interfaceController: CPInterfaceController, window: CPWindow) {
        self.interfaceController = interfaceController
        self.window = window
        super.init()
    }

    // MARK: - ライフサイクル

    func start() {
        window.rootViewController = mapViewController

        let configuration = CPSessionConfiguration(delegate: self)
        sessionConfiguration = configuration
        destinations = CarPlayDestinationBrowser(
            interfaceController: interfaceController,
            sessionConfiguration: configuration,
            onSelect: { [weak self] in self?.navigation.requestRoutes(to: $0) },
            onError: { [weak self] in self?.presentAlert(message: $0) })

        mapTemplate.mapDelegate = self
        mapTemplate.automaticallyHidesNavigationBar = false
        applyIdleButtons()
        interfaceController.setRootTemplate(mapTemplate, animated: true, completion: nil)

        location.requestAuthorization()
        location.startUpdating()
        observeState()
    }

    /// 車から渡される昼夜の指定を地図へ流す（ガイド p.35）。
    /// テンプレート側は CarPlay が自前で切り替えるので、こちらは地図だけでよい。
    func apply(contentStyle: UIUserInterfaceStyle) {
        mapViewController.apply(contentStyle: contentStyle)
    }

    func stop() {
        cancellables.removeAll()
        destinations = nil
        sessionConfiguration = nil
        navigationSession = nil
        currentTrip = nil
        activeManeuver = nil
        isTripPaused = false
    }

    private func observeState() {
        location.$location
            .compactMap { $0 }
            .sink { [weak self] in self?.mapViewController.follow(location: $0) }
            .store(in: &cancellables)

        navigation.$phase
            .sink { [weak self] in self?.apply(phase: $0) }
            .store(in: &cancellables)

        navigation.$progress
            .compactMap { $0 }
            .sink { [weak self] in self?.apply(progress: $0) }
            .store(in: &cancellables)

        navigation.maneuverChanged
            .sink { [weak self] in self?.updateManeuvers(route: $0.route, stepIndex: $0.stepIndex) }
            .store(in: &cancellables)

        navigation.$isRerouting
            .removeDuplicates()
            .sink { [weak self] in self?.apply(isRerouting: $0) }
            .store(in: &cancellables)

        navigation.arrived
            .sink { [weak self] _ in self?.finishSession() }
            .store(in: &cancellables)

        navigation.$lastError
            .compactMap { $0 }
            .sink { [weak self] in self?.presentAlert(message: $0) }
            .store(in: &cancellables)
    }

    // MARK: - 状態の反映

    private func apply(phase: NavigationController.Phase) {
        switch phase {
        case .idle:
            mapTemplate.hideTripPreviews()
            mapViewController.show(route: nil)
            mapViewController.recenter()
            applyIdleButtons()

        case .calculating:
            // ルート計算中は行き先ピンだけ消しておく。テンプレートは触らない。
            mapViewController.show(route: nil)

        case let .previewing(routes):
            guard let first = routes.first else { return }
            mapViewController.show(route: first)
            mapViewController.showRouteOverview(first)
            showTripPreview(for: routes)

        case let .navigating(route):
            mapTemplate.hideTripPreviews()
            mapViewController.show(route: route)
            mapViewController.recenter()
            applyNavigatingButtons()
            beginSessionIfNeeded(for: route)
        }
    }

    private func apply(progress: RouteProgress) {
        guard let trip = currentTrip, let route = navigation.currentRoute else { return }

        mapTemplate.update(CPTravelEstimates(distanceRemaining: .meters(progress.distanceRemaining),
                                             timeRemaining: progress.timeRemaining),
                           for: trip,
                           with: .default)

        if let activeManeuver {
            let timeToManeuver = estimatedTime(forDistance: progress.distanceToNextManeuver, on: route)
            navigationSession?.updateEstimates(
                CPTravelEstimates(distanceRemaining: .meters(progress.distanceToNextManeuver),
                                  timeRemaining: timeToManeuver),
                for: activeManeuver)
        }
    }

    // MARK: - ルート提示

    private func showTripPreview(for routes: [NavRoute]) {
        let trip = makeTrip(for: routes)
        currentTrip = trip

        let configuration = CPTripPreviewTextConfiguration(startButtonTitle: "案内開始",
                                                           additionalRoutesButtonTitle: "他のルート",
                                                           overviewButtonTitle: "全体表示")
        mapTemplate.showTripPreviews([trip], textConfiguration: configuration)
    }

    /// 候補ルートすべてを 1 つの `CPTrip` にまとめる。
    /// CarPlay ではこうすると「他のルート」で切り替えられる。
    private func makeTrip(for routes: [NavRoute]) -> CPTrip {
        let choices = routes.map { route -> CPRouteChoice in
            let summary = Formatters.routeSummary(distance: route.distance, duration: route.expectedTravelTime)
            let choice = CPRouteChoice(summaryVariants: [route.name.isEmpty ? "ルート" : route.name],
                                       additionalInformationVariants: [summary],
                                       selectionSummaryVariants: [summary])
            choice.userInfo = route.id
            return choice
        }

        let destination = routes[0].destination.mapItem
        return CPTrip(origin: MKMapItem.forCurrentLocation(), destination: destination, routeChoices: choices)
    }

    private func route(for choice: CPRouteChoice) -> NavRoute? {
        guard let id = choice.userInfo as? UUID else { return navigation.previewedRoutes.first }
        return navigation.previewedRoutes.first { $0.id == id }
    }

    // MARK: - 案内セッション

    /// iPhone 側で案内を始めた場合もここに来るので、二重開始を防ぐ。
    private func beginSessionIfNeeded(for route: NavRoute) {
        guard navigationSession == nil else { return }

        let trip = currentTrip ?? makeTrip(for: [route])
        currentTrip = trip
        navigationSession = mapTemplate.startNavigationSession(for: trip)

        if let progress = navigation.progress {
            updateManeuvers(route: route, stepIndex: progress.stepIndex)
        }
    }

    private func finishSession() {
        navigationSession?.finishTrip()
        navigationSession = nil
        currentTrip = nil
        activeManeuver = nil
        isTripPaused = false
    }

    private func cancelSession() {
        navigationSession?.cancelTrip()
        navigationSession = nil
        currentTrip = nil
        activeManeuver = nil
        isTripPaused = false
    }

    // MARK: - リルート中の一時停止

    /// 再計算中であることを案内カードに出す。
    ///
    /// 経路を張り替えるのではなく、同じ `CPNavigationSession` を一時停止して、
    /// 新しい経路の情報を渡して再開する。セッションを作り直すと `CPTrip` から
    /// 組み直しになり、到着予定の表示が一度途切れる。
    private func apply(isRerouting: Bool) {
        guard let navigationSession else { return }

        if isRerouting {
            guard !isTripPaused else { return }
            isTripPaused = true
            // description に nil を渡すと CarPlay 側の既定文言（英語環境なら英語）になる。
            // 他の画面の文言に合わせて日本語で出す。
            navigationSession.pauseTrip(for: .rerouting, description: "ルートを再検索中")
        } else {
            guard isTripPaused else { return }
            isTripPaused = false
            resume(navigationSession)
        }
    }

    /// 引き直した経路で案内を再開する。
    ///
    /// `resumeTrip(updatedRouteSegments:currentSegment:rerouteReason:)`（iOS 26.4）は
    /// 経由地ごとに経路を区切る新しいモデルで、区間をセッション開始時から
    /// `addRouteSegments` で積んでおく前提。目的地 1 つしか扱わない現状では
    /// 得るものが無いので、17.4 からある `CPRouteInformation` の側を使う。
    /// デプロイメントターゲットが 26.0 である以上、新しい方は `#available` で
    /// 分岐しないと呼べず、どのみち古い方の実装は消せない。
    /// なお 26.4 で非推奨になったが、26.0 が下限のうちは警告も出ない。
    private func resume(_ session: CPNavigationSession) {
        guard let route = navigation.currentRoute, !route.steps.isEmpty else { return }
        let stepIndex = min(navigation.progress?.stepIndex ?? 0, route.steps.count - 1)

        // 全区間ぶんをここで作り、現在の 2 件はその中から取る。別々に作ると
        // `updateEstimates(for:)` の宛先とインスタンスが食い違う。
        let maneuvers = route.steps.enumerated().map { index, step in
            makeManeuver(for: step,
                         on: route,
                         distance: index == stepIndex ? currentDistanceToManeuver(default: step.distance) : step.distance)
        }
        let upcoming = Array(maneuvers[stepIndex...].prefix(2))

        let tripEstimates = CPTravelEstimates(
            distanceRemaining: .meters(navigation.progress?.distanceRemaining ?? route.distance),
            timeRemaining: navigation.progress?.timeRemaining ?? route.expectedTravelTime)

        session.resumeTrip(updatedRouteInformation: CPRouteInformation(
            maneuvers: maneuvers,
            laneGuidances: [],
            currentManeuvers: upcoming,
            currentLaneGuidance: CPLaneGuidance(),
            trip: tripEstimates,
            maneuverTravelEstimates: upcoming.first?.initialTravelEstimates ?? tripEstimates))

        // `CPRouteInformation` は車線案内を必須で要求するので空のものを渡しているが、
        // セッション側は「無いなら nil」がヘッダの指定。空の車線表示が残らないよう戻す。
        session.currentLaneGuidance = nil
        session.upcomingManeuvers = upcoming
        activeManeuver = upcoming.first
    }

    // MARK: - 案内カード

    /// 次の指示（と、その次）を CarPlay の案内カードに載せる。
    /// CarPlay は 2 件までしか表示しないので 2 件で切る。
    private func updateManeuvers(route: NavRoute, stepIndex: Int) {
        guard route.steps.indices.contains(stepIndex) else { return }

        let maneuvers = route.steps[stepIndex...].prefix(2).enumerated().map { offset, step in
            makeManeuver(for: step,
                         on: route,
                         distance: offset == 0 ? currentDistanceToManeuver(default: step.distance) : step.distance)
        }

        navigationSession?.upcomingManeuvers = Array(maneuvers)
        activeManeuver = maneuvers.first
    }

    private func makeManeuver(for step: NavStep,
                              on route: NavRoute,
                              distance: CLLocationDistance) -> CPManeuver {
        let maneuver = CPManeuver()
        maneuver.instructionVariants = [step.instruction]
        maneuver.symbolImage = ManeuverSymbol.image(for: step.instruction)
        maneuver.initialTravelEstimates = CPTravelEstimates(
            distanceRemaining: .meters(distance),
            timeRemaining: estimatedTime(forDistance: step.distance, on: route))
        return maneuver
    }

    private func currentDistanceToManeuver(default fallback: CLLocationDistance) -> CLLocationDistance {
        navigation.progress?.distanceToNextManeuver ?? fallback
    }

    /// step 単位の所要時間は MapKit が返さないため、経路全体の平均速度で割り当てる。
    private func estimatedTime(forDistance meters: CLLocationDistance, on route: NavRoute) -> TimeInterval {
        guard route.distance > 0 else { return 0 }
        return route.expectedTravelTime * (meters / route.distance)
    }

    // MARK: - ボタン

    /// 並び順に意味がある。**パン UI に入ると先頭 2 つしか残らない**
    /// （超過ぶんは配列の末尾から順に隠される）ので、パン UI 側で用の無いものほど後ろに置く。
    /// パンボタン自身はパン UI の中では押しても意味が無いため最後。
    ///
    /// 現在地ボタンを案内中と同じ位置（先頭）に置くのは、指でドラッグして地図を
    /// 動かしたあと自車位置に戻る手段が他に無いため。案内中と押す場所も揃う。
    private func applyIdleButtons() {
        mapTemplate.mapButtons = [recenterButton, zoomInButton, zoomOutButton, panButton]
        mapTemplate.leadingNavigationBarButtons = []
        mapTemplate.trailingNavigationBarButtons = [destinationsButton]
    }

    private func applyNavigatingButtons() {
        mapTemplate.mapButtons = [recenterButton, zoomInButton, zoomOutButton]
        mapTemplate.leadingNavigationBarButtons = [overviewButton]
        mapTemplate.trailingNavigationBarButtons = [endNavigationButton]
    }

    private var destinationsButton: CPBarButton {
        CPBarButton(title: "目的地") { [weak self] _ in self?.destinations?.present() }
    }

    private var endNavigationButton: CPBarButton {
        CPBarButton(title: "案内終了") { [weak self] _ in
            self?.cancelSession()
            self?.navigation.cancelNavigation()
        }
    }

    private var donePanningButton: CPBarButton {
        CPBarButton(title: "完了") { [weak self] _ in
            self?.mapTemplate.dismissPanningInterface(animated: true)
        }
    }

    private var overviewButton: CPBarButton {
        CPBarButton(title: "全体表示") { [weak self] _ in
            guard let route = self?.navigation.currentRoute else { return }
            self?.mapViewController.showRouteOverview(route)
        }
    }

    private var panButton: CPMapButton {
        let button = CPMapButton { [weak self] _ in
            self?.mapTemplate.showPanningInterface(animated: true)
        }
        button.image = UIImage(systemName: "arrow.up.and.down.and.arrow.left.and.right")
        return button
    }

    private var recenterButton: CPMapButton {
        let button = CPMapButton { [weak self] _ in self?.mapViewController.recenter() }
        button.image = UIImage(systemName: "location.fill")
        return button
    }

    private var zoomInButton: CPMapButton {
        let button = CPMapButton { [weak self] _ in self?.mapViewController.zoomIn() }
        button.image = UIImage(systemName: "plus.magnifyingglass")
        return button
    }

    private var zoomOutButton: CPMapButton {
        let button = CPMapButton { [weak self] _ in self?.mapViewController.zoomOut() }
        button.image = UIImage(systemName: "minus.magnifyingglass")
        return button
    }

    // MARK: - 通知

    private func presentAlert(message: String) {
        let alert = CPAlertTemplate(titleVariants: [message],
                                    actions: [CPAlertAction(title: "OK", style: .default) { [weak self] _ in
                                        self?.interfaceController.dismissTemplate(animated: true, completion: nil)
                                    }])
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }
}

// MARK: - CPMapTemplateDelegate

extension CarPlayCoordinator: CPMapTemplateDelegate {
    func mapTemplate(_ mapTemplate: CPMapTemplate, startedTrip trip: CPTrip, using routeChoice: CPRouteChoice) {
        mapTemplate.hideTripPreviews()
        guard let route = route(for: routeChoice) else { return }
        navigation.startNavigation(with: route)
    }

    func mapTemplateDidCancelNavigation(_ mapTemplate: CPMapTemplate) {
        navigationSession = nil
        currentTrip = nil
        activeManeuver = nil
        isTripPaused = false
        navigation.cancelNavigation()
    }

    /// 「他のルート」で候補を切り替えたとき、地図側の線も差し替える。
    func mapTemplate(_ mapTemplate: CPMapTemplate, selectedPreviewFor trip: CPTrip, using routeChoice: CPRouteChoice) {
        guard let route = route(for: routeChoice) else { return }
        mapViewController.show(route: route)
        mapViewController.showRouteOverview(route)
    }

    // MARK: パン操作

    /// **パン UI から抜ける導線は必ずこちらで出す**。CarPlay が自前で「完了」を出すのは
    /// POI テンプレートだけで、`CPMapTemplate` には無い。出さないと地図を動かしたきり
    /// 元の画面に戻れなくなる。パン中は CarPlay が map ボタンを隠すので、
    /// 置き換えるのはナビゲーションバーのボタンだけでよい。
    func mapTemplateDidShowPanningInterface(_ mapTemplate: CPMapTemplate) {
        mapViewController.setFollowingUser(false)
        mapTemplate.leadingNavigationBarButtons = []
        mapTemplate.trailingNavigationBarButtons = [donePanningButton]
    }

    func mapTemplateDidDismissPanningInterface(_ mapTemplate: CPMapTemplate) {
        mapViewController.recenter()
        // パンに入る前のボタンへ戻す。案内中に入った場合もあるので状態を見て選ぶ。
        if case .navigating = navigation.phase {
            applyNavigatingButtons()
        } else {
            applyIdleButtons()
        }
    }

    // MARK: 指でのドラッグ

    /// タッチに対応した車では、**パン UI に入らなくても**指の動きがそのまま届く。
    /// ただし届くかどうかは車次第（ノブやトラックパッドしか無い車もある）なので、
    /// パンボタンは外せない。ガイド p.33 が「パン UI へ入るボタンを必ず置くこと」を
    /// 求めているのはこのため。

    func mapTemplateDidBeginPanGesture(_ mapTemplate: CPMapTemplate) {
        lastPanTranslation = .zero
    }

    /// `translation` は `UIPanGestureRecognizer` と同じく**ジェスチャ開始からの累積値**。
    /// そのまま渡すと動かすほど加速するので、前回との差分だけを地図へ送る。
    /// 指に貼り付いて見えるよう、ドラッグ中はアニメーションを掛けない。
    func mapTemplate(_ mapTemplate: CPMapTemplate,
                     didUpdatePanGestureWithTranslation translation: CGPoint,
                     velocity: CGPoint) {
        mapViewController.pan(by: CGPoint(x: translation.x - lastPanTranslation.x,
                                          y: translation.y - lastPanTranslation.y),
                              animated: false)
        lastPanTranslation = translation
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, didEndPanGestureWithVelocity velocity: CGPoint) {
        lastPanTranslation = .zero
    }

    /// ノブやボタンでの方向入力。1 回あたり画面の約 1/4 だけ動かす。
    func mapTemplate(_ mapTemplate: CPMapTemplate, panWith direction: CPMapTemplate.PanDirection) {
        let step: CGFloat = 100
        var translation = CGPoint.zero
        if direction.contains(.left) { translation.x += step }
        if direction.contains(.right) { translation.x -= step }
        if direction.contains(.up) { translation.y += step }
        if direction.contains(.down) { translation.y -= step }
        mapViewController.pan(by: translation)
    }
}

// MARK: - CPSessionConfigurationDelegate

extension CarPlayCoordinator: CPSessionConfigurationDelegate {
    /// 走行の開始・停止に合わせて車が UI 制限を掛け外しする。
    /// キーボードが塞がれると検索ボタンを出す意味が無くなるので、
    /// 目的地リストを作り直させる。
    func sessionConfiguration(_ sessionConfiguration: CPSessionConfiguration,
                              limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface) {
        guard case .idle = navigation.phase else { return }
        applyIdleButtons()
    }
}

private extension Measurement where UnitType == UnitLength {
    static func meters(_ value: CLLocationDistance) -> Measurement<UnitLength> {
        Measurement(value: value, unit: .meters)
    }
}
