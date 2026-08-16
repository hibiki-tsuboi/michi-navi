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
    private var voiceControl: CarPlayVoiceControl?

    private var navigationSession: CPNavigationSession?
    private var currentTrip: CPTrip?
    private var activeManeuver: CPManeuver?
    /// `pauseTrip` を出したかどうか。自分で止めたときだけ再開する。
    /// 止めていないのに `resumeTrip` を投げると CarPlay 側の状態と食い違う。
    private var isTripPaused = false

    /// いま案内している経路の全 `CPManeuver`。`upcomingManeuvers` に載せるものも
    /// `CPRouteInformation` に渡すものも、必ずこの配列から取る。別インスタンスを混ぜると
    /// `updateEstimates(for:)` の宛先が食い違う。
    private var routeManeuvers: [CPManeuver] = []
    /// `routeManeuvers` がどの経路のものか。リルートで作り直す判断に使う。
    private var maneuverRouteID: UUID?
    /// 車へ経路を渡す係（iOS 26.4 以降）。
    ///
    /// 型が 26.4 でしか存在せず、**格納プロパティには `@available` を付けられない**ので、
    /// `AnyObject` で持って `routeSharing` から取り出す。
    private var routeSharingBox: AnyObject?
    private var cancellables = Set<AnyCancellable>()

    @available(iOS 26.4, *)
    private var routeSharing: CarPlayRouteSharing? { routeSharingBox as? CarPlayRouteSharing }

    /// 案内中に経路が入れ替わった理由。`CPRerouteReason`（iOS 26.4）へ変換して車へ渡す。
    /// `CPRerouteReason` をそのまま持ち回ると、26.0 でも通る場所に 26.4 の型が漏れる。
    private enum RouteChangeReason {
        /// 経路を外れたので引き直した。
        case offRoute
        /// 立ち寄り先が増減した。
        case waypointChanged

        @available(iOS 26.4, *)
        var carPlayReason: CPRerouteReason {
            switch self {
            case .offRoute: .missedTurn
            case .waypointChanged: .waypointModified
            }
        }
    }

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
        let select: (CarPlayDestinationBrowser.Choice) -> Void = { [weak self] choice in
            switch choice {
            case let .destination(place): self?.navigation.requestRoutes(to: place)
            case let .waypoint(place): self?.navigation.addWaypoint(place)
            }
        }
        destinations = CarPlayDestinationBrowser(
            interfaceController: interfaceController,
            sessionConfiguration: configuration,
            onSelect: select,
            onError: { [weak self] in self?.presentAlert(message: $0) })
        voiceControl = CarPlayVoiceControl(
            interfaceController: interfaceController,
            onSelect: select,
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
        voiceControl = nil
        sessionConfiguration = nil
        clearSession()
    }

    /// セッションまわりの持ち物を一度に捨てる。終了・中止・シーン切断で通る道が
    /// 4 本あり、片方だけ足し忘れると次の案内に前回の残骸が混ざる。
    private func clearSession() {
        navigationSession = nil
        currentTrip = nil
        activeManeuver = nil
        routeManeuvers = []
        maneuverRouteID = nil
        routeSharingBox = nil
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
            navigationSession?.maneuverState = maneuverState(forDistance: progress.distanceToNextManeuver)
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
            // 有料道路・通行規制などの注意を要約に足す。variants は「入るなら長い方」を
            // 選ぶ仕組みなので、幅の狭い車では自動的に注意なしの表記へ落ちる。
            let variants = route.advisoryNotices.isEmpty
                ? [summary]
                : ["\(summary)・\(route.advisoryNotices.joined(separator: "、"))", summary]

            let choice = CPRouteChoice(summaryVariants: [route.name.isEmpty ? "ルート" : route.name],
                                       additionalInformationVariants: variants,
                                       selectionSummaryVariants: variants)
            choice.userInfo = route.id
            return choice
        }

        let route = routes[0]
        let trip: CPTrip
        if #available(iOS 26.4, *) {
            // 26.4 で `MKMapItem` 版の初期化は非推奨になり、地点は `CPNavigationWaypoint` で
            // 渡す形になった。**ルート共有はこちらでないと成立しない**（区間の始点・終点も
            // 同じ型）。出発地に `MKMapItem.forCurrentLocation()` を使わないのは、あれが
            // 座標を持たない特別な項目で、車へ渡す地点にはならないため。
            trip = CPTrip(originWaypoint: CarPlayRouteSharing.waypoint(
                              at: route.coordinates.first ?? route.destination.coordinate,
                              name: "現在地"),
                          destinationWaypoint: CarPlayRouteSharing.waypoint(for: route.destination),
                          routeChoices: choices)
        } else {
            trip = CPTrip(origin: MKMapItem.forCurrentLocation(),
                          destination: route.destination.mapItem,
                          routeChoices: choices)
        }

        // 目的地を車の純正ナビへ渡せることを申告する（ガイド p.60）。対応した車でだけ
        // ルート選択画面に共有ボタンが出るので、いつでも立てておいてよい。
        if #available(iOS 26.1, *) { trip.hasShareableDestination = true }
        return trip
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
        let session = mapTemplate.startNavigationSession(for: trip)
        navigationSession = session

        // 進捗が出る前でも先に全区間を渡す。車のメーターや HUD へは
        // 「できるだけ早く、できるだけ多く」渡すのが決まり（ガイド p.56）。
        let stepIndex = navigation.progress?.stepIndex ?? 0
        rebuildManeuvers(for: route, stepIndex: stepIndex, isNewSession: true)

        // 経路の区間を積むのは maneuver を組み終えたあと。区間の中に入れる `CPManeuver` は
        // `routeManeuvers` と同じインスタンスでなければならない。
        if #available(iOS 26.4, *) {
            let sharing = CarPlayRouteSharing()
            routeSharingBox = sharing
            sharing.begin(session: session,
                          route: route,
                          maneuvers: routeManeuvers,
                          stepIndex: stepIndex,
                          tripEstimates: tripEstimates(for: route))
        }
    }

    private func finishSession() {
        navigationSession?.finishTrip()
        clearSession()
    }

    private func cancelSession() {
        navigationSession?.cancelTrip()
        clearSession()
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
            resume(navigationSession, reason: .offRoute)
        }
    }

    /// 案内中に経路そのものが入れ替わったことを CarPlay と車へ伝える。
    ///
    /// 立ち寄り先が増えたときに通る。逸脱による引き直しは `apply(isRerouting:)` が
    /// 止めるところと再開するところの両方を担うので、ここには来ない。
    ///
    /// **素通しで `resumeTrip` を投げないこと。** 経路を変えるときは一度 `pauseTrip` で
    /// 止めてから渡し直す、というのがガイド p.61 の手順で、止めずに渡すと車側が
    /// 前の経路を掴んだままになる。
    private func replaceRoute(reason: RouteChangeReason) {
        guard let navigationSession else { return }
        navigationSession.pauseTrip(for: .rerouting, description: "ルートを引き直し中")
        resume(navigationSession, reason: reason)
    }

    /// 引き直した経路で案内を再開する。
    ///
    /// iOS 26.4 からは**経由地ごとに区切った `CPRouteSegment` の配列**で渡す形になり、
    /// 17.4 からの `CPRouteInformation` は非推奨になった（26.0 が下限のうちは警告は出ない）。
    /// 新しい方に寄せているのは経由地の表現力のためではなく、**ルート共有が
    /// そちらでしか成立しない**ため。車へ経路を預けるには区間を積んでおく必要がある。
    /// 26.0〜26.3 では区間を作れないので、古い方をそのまま残してある。
    private func resume(_ session: CPNavigationSession, reason: RouteChangeReason) {
        // 経路の差し替えは maneuverChanged が先に済ませているので、ここでは
        // 出来上がっている routeManeuvers をそのまま渡す。
        guard let route = navigation.currentRoute, !routeManeuvers.isEmpty else { return }
        let stepIndex = min(navigation.progress?.stepIndex ?? 0, routeManeuvers.count - 1)
        let upcoming = Array(routeManeuvers[stepIndex...].prefix(2))
        let estimates = tripEstimates(for: route)

        if #available(iOS 26.4, *), let routeSharing {
            routeSharing.resume(session: session,
                                route: route,
                                maneuvers: routeManeuvers,
                                stepIndex: stepIndex,
                                tripEstimates: estimates,
                                reason: reason.carPlayReason)
        } else {
            session.resumeTrip(updatedRouteInformation: CPRouteInformation(
                maneuvers: routeManeuvers,
                laneGuidances: [],
                currentManeuvers: upcoming,
                currentLaneGuidance: CPLaneGuidance(),
                trip: estimates,
                maneuverTravelEstimates: upcoming.first?.initialTravelEstimates ?? estimates))
        }

        // どちらの渡し方でも車線案内は必須で要求されるので空のものを入れているが、
        // セッション側は「無いなら nil」がヘッダの指定。空の車線表示が残らないよう戻す。
        session.currentLaneGuidance = nil
        session.upcomingManeuvers = upcoming
        activeManeuver = upcoming.first
    }

    /// 目的地までの残りの見積もり。進捗が出ていなければ経路全体の値を使う。
    private func tripEstimates(for route: NavRoute) -> CPTravelEstimates {
        CPTravelEstimates(
            distanceRemaining: .meters(navigation.progress?.distanceRemaining ?? route.distance),
            timeRemaining: navigation.progress?.timeRemaining ?? route.expectedTravelTime)
    }

    // MARK: - 案内カード

    private func updateManeuvers(route: NavRoute, stepIndex: Int) {
        if maneuverRouteID == route.id {
            showManeuvers(from: stepIndex)
        } else {
            // 経路が入れ替わった。作り直して渡し直す。
            let hadRoute = maneuverRouteID != nil
            rebuildManeuvers(for: route, stepIndex: stepIndex, isNewSession: false)

            // 逸脱による引き直しなら、止めたのも再開するのも `apply(isRerouting:)` の
            // 仕事なので触らない。止まっていないのに経路が変わったということは、
            // 立ち寄り先が増えた（＝こちらで渡し直す必要がある）ということ。
            if hadRoute, !isTripPaused { replaceRoute(reason: .waypointChanged) }
        }
        presentNotice(of: route, at: stepIndex)
    }

    /// MapKit が区間に付けてくる注意（料金所・車線規制など）を、その区間に入るときに出す。
    ///
    /// 区間が変わったときにしか呼ばれないので、同じ注意が繰り返し出ることはない。
    /// 自動で消えるようにして、運転中に操作を求めない。
    private func presentNotice(of route: NavRoute, at stepIndex: Int) {
        guard route.steps.indices.contains(stepIndex),
              let notice = route.steps[stepIndex].notice,
              !notice.isEmpty else { return }

        let alert = CPNavigationAlert(
            titleVariants: [notice],
            subtitleVariants: nil,
            image: UIImage(systemName: "exclamationmark.triangle.fill"),
            primaryAction: CPAlertAction(title: "OK", style: .default) { _ in },
            secondaryAction: nil,
            duration: 8)
        mapTemplate.present(navigationAlert: alert, animated: true)
    }

    /// 経路の全区間を `CPManeuver` にして、セッションへ渡す。
    ///
    /// `add(_:)` は**セッションを始めたときだけ**呼ぶ。あれは積み上げる API で、
    /// 引き直すたびに全区間を渡すとセッションの中に古い経路のぶんが溜まり続ける。
    /// 引き直したあとの並びは `resumeTrip(updatedRouteInformation:)` が運ぶので、
    /// こちらから足す必要はない。
    private func rebuildManeuvers(for route: NavRoute, stepIndex: Int, isNewSession: Bool) {
        routeManeuvers = route.steps.enumerated().map { index, step in
            makeManeuver(for: step,
                         on: route,
                         distance: index == stepIndex ? currentDistanceToManeuver(default: step.distance) : step.distance)
        }
        maneuverRouteID = route.id

        if isNewSession { navigationSession?.add(routeManeuvers) }
        showManeuvers(from: stepIndex)
    }

    /// 次の指示（と、その次）を CarPlay の案内カードに載せる。
    /// CarPlay は 2 件までしか表示しないので 2 件で切る。
    private func showManeuvers(from stepIndex: Int) {
        guard routeManeuvers.indices.contains(stepIndex) else { return }

        let upcoming = Array(routeManeuvers[stepIndex...].prefix(2))
        navigationSession?.upcomingManeuvers = upcoming
        // 指示が切り替わった直後であることを車へ伝える。
        // 以降は距離に応じて apply(progress:) が prepare / execute へ進める。
        navigationSession?.maneuverState = .initial
        activeManeuver = upcoming.first

        // 区間をまたいだかを見る。経由地を通過した瞬間がこれにあたる。
        // 経路が入れ替わった直後はまだ区間が古いので、どの経路のものかを渡して弾かせる。
        if #available(iOS 26.4, *), let navigationSession, let maneuverRouteID {
            routeSharing?.updateCurrentSegment(session: navigationSession,
                                               routeID: maneuverRouteID,
                                               stepIndex: stepIndex)
        }
    }

    private func makeManeuver(for step: NavStep,
                              on route: NavRoute,
                              distance: CLLocationDistance) -> CPManeuver {
        let kind = ManeuverKind.inferred(from: step.instruction)

        let maneuver = CPManeuver()
        maneuver.instructionVariants = [step.instruction]
        maneuver.symbolImage = kind.image
        // 画面のアイコンだけでなく、車のメーター・HUD へもこの型で送られる。
        maneuver.maneuverType = kind.type
        maneuver.initialTravelEstimates = CPTravelEstimates(
            distanceRemaining: .meters(distance),
            timeRemaining: estimatedTime(forDistance: step.distance, on: route))
        return maneuver
    }

    /// 曲がる地点までの距離から、車に見せる段階を決める。
    /// しきい値は音声の予告（`VoicePromptScheduler`）と揃えてある。
    private func maneuverState(forDistance meters: CLLocationDistance) -> CPManeuverState {
        switch meters {
        case ..<200: .execute
        case ..<1_000: .prepare
        default: .continue
        }
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

    /// 現在地ボタンを案内中と同じ位置（先頭）に置くのは、指でドラッグして地図を
    /// 動かしたあと自車位置に戻る手段が他に無いため。案内中と押す場所も揃う。
    /// 上限の 4 つちょうどなので、足すなら何かを外すことになる。
    ///
    /// パン UI に入るとここの並びは使われない。2 つしか残せないので
    /// `mapTemplateDidShowPanningInterface` で差し替えている。
    private func applyIdleButtons() {
        mapTemplate.mapButtons = [recenterButton, zoomInButton, zoomOutButton, panButton]
        mapTemplate.leadingNavigationBarButtons = [voiceButton]
        mapTemplate.trailingNavigationBarButtons = [destinationsButton]
    }

    /// 向きの切り替えは案内中だけ出す。押す場所を変えないよう、前 3 つは
    /// `applyIdleButtons` と同じ並びにしてある。
    private func applyNavigatingButtons() {
        mapTemplate.mapButtons = navigatingMapButtons
        // ナビゲーションバーは左右 2 つずつが上限。マップボタンは 4 つで埋まっている
        // （しかもパン UI に入ると 2 つ落ちる）ので、音声はこちらへ置く。
        mapTemplate.leadingNavigationBarButtons = [voiceButton, overviewButton]
        mapTemplate.trailingNavigationBarButtons = [endNavigationButton]
    }

    private var navigatingMapButtons: [CPMapButton] {
        [recenterButton, zoomInButton, zoomOutButton, orientationButton]
    }

    private func toggleMapOrientation() {
        MapOrientation.current = MapOrientation.current.toggled
        mapViewController.apply(orientation: MapOrientation.current)
        // アイコンを新しい向きに差し替える。ナビゲーションバー側は変わらないので触らない。
        mapTemplate.mapButtons = navigatingMapButtons
    }

    private var destinationsButton: CPBarButton {
        CPBarButton(title: "目的地") { [weak self] _ in self?.destinations?.present() }
    }

    /// 押して話す。**走行中でも押せる唯一の「新しい行き先を決める」導線**なので、
    /// キーボードの封じられ具合に関係なく常に出す（`CarPlayDestinationBrowser` の
    /// 検索ボタンとは扱いが違う）。
    private var voiceButton: CPBarButton {
        CPBarButton(image: UIImage(systemName: "mic.fill") ?? UIImage()) { [weak self] _ in
            self?.voiceControl?.start()
        }
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

    /// 地図の向きの切り替え。アイコンは**いまの向き**を表す
    /// （押した先ではなく現在の状態が読めるようにする）。
    private var orientationButton: CPMapButton {
        let button = CPMapButton { [weak self] _ in self?.toggleMapOrientation() }
        button.image = UIImage(systemName: MapOrientation.current == .north
            ? "location.north.line.fill"
            : "car.fill")
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
    /// 案内の内容を車へ渡すことを宣言する。これを true にして初めて、
    /// `CPManeuver.maneuverType` などがメーターや HUD に送られる（ガイド p.56）。
    /// デジタルメーターを持たない車でも受け取れるので、常に渡す。
    func mapTemplateShouldProvideNavigationMetadata(_ mapTemplate: CPMapTemplate) -> Bool {
        true
    }

    // MARK: 車との経路の受け渡し（iOS 26.4）

    /// 経路そのものを車へ預けることを宣言する（ガイド p.61）。
    ///
    /// 目的地だけを渡す共有と違い、こちらは形・指示・座標列まで渡す。先進運転支援を
    /// 積んだ車はそれを見て車線案内を出したり、走り方をこちらの経路へ寄せたりする。
    /// 中身を `CPRouteSegment` に組むのは `CarPlayRouteSharing`。
    /// 対応していない車では何も起きないだけなので、常に渡す。
    @available(iOS 26.4, *)
    func mapTemplateShouldProvideRouteSharing(_ mapTemplate: CPMapTemplate) -> Bool {
        true
    }

    /// 車が経路をどう扱っているかが変わった。こちらから直すところは無いので記録だけ。
    @available(iOS 26.4, *)
    func mapTemplate(_ mapTemplate: CPMapTemplate, didReceiveUpdatedRouteSource routeSource: CPRouteSource) {
        CarPlayVehicleLog.routeSource(routeSource)
    }

    /// 車から「ここへ寄れ」と提案が来る。EV が航続距離を見て充電を挟ませるのが代表例。
    ///
    /// 確認の見た目は CarPlay 既定のものに任せる。そのぶん**こちらの仕事は「寄った場合の
    /// 所要」を返すことだけ**で、完了ハンドラを呼ぶまでカードは出ない。逆に呼ばなければ
    /// 既定のカードは出ない（自前の UI を出したいときの作法）ので、
    /// **試算に失敗したときは黙って落とす**。数字の入っていないカードを運転中に見せない。
    @available(iOS 26.4, *)
    func mapTemplate(_ mapTemplate: CPMapTemplate,
                     didRequestToInsert waypoint: CPNavigationWaypoint,
                     into segment: CPRouteSegment,
                     completion: @escaping (CPTravelEstimates) -> Void) {
        guard let place = Place(vehicleWaypoint: waypoint) else { return }
        CarPlayVehicleLog.waypointProposed(name: place.name)

        Task {
            guard let estimate = await navigation.estimate(inserting: place) else {
                CarPlayVehicleLog.waypointEstimated(succeeded: false)
                return
            }
            CarPlayVehicleLog.waypointEstimated(succeeded: true)
            completion(CPTravelEstimates(distanceRemaining: .meters(estimate.distance),
                                         timeRemaining: estimate.travelTime))
        }
    }

    /// 提案を受けるかどうかが決まった。受けたなら経路に挟んで引き直す。
    ///
    /// 引き直した結果は `updateManeuvers` から `replaceRoute(reason: .waypointChanged)` に
    /// 入り、そこで新しい区間が車へ渡る。ここで `resumeTrip` を呼ばないのは、
    /// **新しい経路がまだ出来ていない**ため（`addWaypoint` は非同期に計算する）。
    @available(iOS 26.4, *)
    func mapTemplate(_ mapTemplate: CPMapTemplate,
                     waypoint: CPNavigationWaypoint,
                     accepted: Bool,
                     forSegment segment: CPRouteSegment?) {
        CarPlayVehicleLog.waypointDecided(accepted: accepted)
        guard accepted, let place = Place(vehicleWaypoint: waypoint) else { return }
        navigation.addWaypoint(place)
    }

    /// 案内していないときに、車から目的地そのものが送られてくる。
    ///
    /// ガイド p.61 の指示どおりルートの提示までにとどめ、開始は利用者に選ばせる。
    /// `startNavigation(to:)` で即発進させると、車の操作だけで走り出すことになる。
    @available(iOS 26.4, *)
    func mapTemplate(_ mapTemplate: CPMapTemplate, didReceiveRequestForDestination waypoint: CPNavigationWaypoint) {
        guard let place = Place(vehicleWaypoint: waypoint) else { return }
        CarPlayVehicleLog.destinationRequested(name: place.name)
        navigation.requestRoutes(to: place)
    }

    /// 目的地を車の純正ナビへ渡せた。確認のカードは CarPlay が既に出しているので何もしない。
    @available(iOS 26.4, *)
    func mapTemplate(_ mapTemplate: CPMapTemplate, didShareDestinationFor trip: CPTrip) {
        CarPlayVehicleLog.destinationShared(succeeded: true)
    }

    /// 車が受け取れなかった。押した本人は結果を待っているので、ここだけは画面に出す。
    @available(iOS 26.4, *)
    func mapTemplate(_ mapTemplate: CPMapTemplate, didFailToShareDestinationFor trip: CPTrip, error: any Error) {
        CarPlayVehicleLog.destinationShared(succeeded: false)
        presentAlert(message: "目的地を車に送れませんでした")
    }

    // MARK: 案内の開始と終了

    func mapTemplate(_ mapTemplate: CPMapTemplate, startedTrip trip: CPTrip, using routeChoice: CPRouteChoice) {
        mapTemplate.hideTripPreviews()
        guard let route = route(for: routeChoice) else { return }
        navigation.startNavigation(with: route)
    }

    func mapTemplateDidCancelNavigation(_ mapTemplate: CPMapTemplate) {
        // CarPlay 側が既に畳んでいるので finishTrip / cancelTrip は呼ばない。
        clearSession()
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

        // **パン中に残せるマップボタンは 2 つだけ**で、超過ぶんは配列の末尾から
        // CarPlay が勝手に隠す。並び順まかせにすると縮小が落ちるので、ここで
        // 明示的に置き換える。パン中に意味があるのは拡大・縮小だけで、
        // 現在地へ戻すのは「完了」が担い、パンボタン自身はもう用がない。
        mapTemplate.mapButtons = [zoomInButton, zoomOutButton]
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
    ///
    /// `translation` は名前に反して**前回の呼び出しからの差分**。CarPlay 側の実体は
    /// `clientPanGestureWithDeltaPoint:velocity:` で、押した点と前回の点の引き算を
    /// 送ってくる（iOS 18.6 でも同じ）。`UIPanGestureRecognizer` と同じ累積値だと
    /// 思ってここでさらに差分を取ると、デルタを微分することになり、等速でドラッグ
    /// しても地図がほとんど動かず、指を加減速したときだけガタつく。そのまま渡すこと。
    ///
    /// 指に貼り付いて見えるよう、ドラッグ中はアニメーションを掛けない。
    func mapTemplate(_ mapTemplate: CPMapTemplate,
                     didUpdatePanGestureWithTranslation translation: CGPoint,
                     velocity: CGPoint) {
        CarPlayGestureLog.drag(translation: translation, velocity: velocity)
        mapViewController.pan(by: translation, animated: false)
    }

    // MARK: ピンチ・回転・傾け（iOS 26）

    /// ここから 9 つは `CPMapTemplateDelegate` の**任意**メソッド。名前を 1 文字でも
    /// 間違えると、コンパイルは通ったまま黙って呼ばれなくなる。増やすときは
    /// `#selector(CPMapTemplateDelegate.xxx)` が解決するかで確かめること。

    func mapTemplateDidBeginZoomGesture(_ mapTemplate: CPMapTemplate) {
        CarPlayGestureLog.zoomBegan()
        mapViewController.beginZoomGesture()
    }

    /// ピンチとタップの両方がここに来る。ピンチは開始 → 更新 → 終了と続き、`scale` は
    /// ジェスチャ開始からの累積倍率。いっぽう**ダブルタップ（拡大）と 2 本指タップ
    /// （縮小）は開始も終了も無しに 1 回だけ来て、`scale` は 1.0、`velocity` は ±1.0**
    /// という定数で埋められている（向きは符号だけが持つ）。
    ///
    /// **開始を受け取ったかどうかでは見分けないこと。** CarPlay 側の
    /// `_handlePinchGesture:` は `UIGestureRecognizerState` を began / changed / ended の
    /// 3 つでしか分岐しておらず、**cancelled では終了を送ってこない**。着信や Siri で
    /// タッチが取り消されると終了が落ち、「ピンチ中」の印が残ったままになる。
    /// 定数の組で見分ければ、その取りこぼしに寄りかからずに済む。
    func mapTemplate(_ mapTemplate: CPMapTemplate,
                     didUpdateZoomGestureWithCenter center: CGPoint,
                     scale: CGFloat,
                     velocity: CGFloat) {
        let isTap = scale == 1 && abs(velocity) == 1
        if isTap {
            // タップ。拡大・縮小ボタンと同じ 1 段ぶんだけ動かす。
            if velocity > 0 { mapViewController.zoomIn() } else { mapViewController.zoomOut() }
        } else {
            mapViewController.zoom(toScale: scale)
        }
        CarPlayGestureLog.zoom(center: center, scale: scale, velocity: velocity,
                               isTap: isTap, camera: mapViewController.cameraSummary)
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, didEndZoomGestureWithVelocity velocity: CGFloat) {
        CarPlayGestureLog.zoomEnded(velocity: velocity)
        mapViewController.endZoomGesture()
    }

    func mapTemplateDidBeginRotationGesture(_ mapTemplate: CPMapTemplate) {
        CarPlayGestureLog.rotationBegan()
        mapViewController.beginRotationGesture()
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate,
                     didRotateWithCenter center: CGPoint,
                     rotation: CGFloat,
                     velocity: CGFloat) {
        mapViewController.rotate(byRadians: rotation)
        CarPlayGestureLog.rotation(center: center, radians: rotation, velocity: velocity,
                                   camera: mapViewController.cameraSummary)
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, rotationDidEndWithVelocity velocity: CGFloat) {
        CarPlayGestureLog.rotationEnded(velocity: velocity)
        mapViewController.endRotationGesture()
    }

    func mapTemplateDidBeginPitchGesture(_ mapTemplate: CPMapTemplate) {
        CarPlayGestureLog.pitchBegan()
        mapViewController.beginPitchGesture()
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, pitchWithCenter center: CGPoint) {
        mapViewController.pitch(towards: center)
        CarPlayGestureLog.pitch(center: center, camera: mapViewController.cameraSummary)
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, pitchEndedWithCenter center: CGPoint) {
        CarPlayGestureLog.pitchEnded(center: center)
        mapViewController.endPitchGesture()
    }

    // MARK: ノブ・トラックパッドでのパン

    /// ノブやボタンでの方向入力。1 回あたり画面の約 1/4 だけ動かす。
    func mapTemplate(_ mapTemplate: CPMapTemplate, panWith direction: CPMapTemplate.PanDirection) {
        let step: CGFloat = 100
        var translation = CGPoint.zero
        if direction.contains(.left) { translation.x += step }
        if direction.contains(.right) { translation.x -= step }
        if direction.contains(.up) { translation.y += step }
        if direction.contains(.down) { translation.y -= step }
        CarPlayGestureLog.pan(direction: direction)
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
