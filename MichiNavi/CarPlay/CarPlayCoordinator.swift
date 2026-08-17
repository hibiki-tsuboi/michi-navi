import CarPlay
import Combine
import MapKit

/// `Core/` の `RouteChangeReason` を指すための別名。
///
/// `CarPlayCoordinator` の中では同名の入れ子の enum が名前を覆うので、そのままでは
/// あちらを書けない（同じモジュール内なので修飾子で分ける手も無い）。**ファイルの
/// 外周では素の名前が `Core/` 側を指す**ので、ここで別名を付けておく。
private typealias CoreRouteChangeReason = RouteChangeReason

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
    /// いま `pauseTrip` で止めている理由。止めていなければ nil。
    ///
    /// **自分で止めたときだけ再開する**（止めていないのに `resumeTrip` を投げると
    /// CarPlay 側の状態と食い違う）。理由まで持っているのは、止める事情が 2 つあるのに
    /// **カードに出せる理由は 1 つだけ**だから（[refreshTripPause]）。
    private var pauseReason: TripPause?

    /// 案内カードを止める理由。上にあるものが優先。
    private enum TripPause {
        /// 経路を外れて引き直している。
        case rerouting
        /// まだ経路に乗っていない。駐車場や施設の中から案内を始めたとき、
        /// **車道へ出るまでこの状態が続く**（`GuidanceEngine.hasJoinedRoute`）。
        case proceedToRoute
    }

    /// いま案内している経路の全 `CPManeuver`。`upcomingManeuvers` に載せるものも
    /// `CPRouteInformation` に渡すものも、必ずこの配列から取る。別インスタンスを混ぜると
    /// `updateEstimates(for:)` の宛先が食い違う。
    private var routeManeuvers: [CPManeuver] = []
    /// `routeManeuvers` がどの経路のものか。リルートで作り直す判断に使う。
    private var maneuverRouteID: UUID?
    /// 最後に車へ渡した経路の指紋。**「道が本当に入れ替わったか」はこれで見る。**
    ///
    /// `maneuverRouteID` では見分けられない。`NavRoute.id` は生成のたびに変わる UUID で、
    /// 同じ道を同じ順に曲がる経路でも別物になるため（`NavRoute.signature` と `id` の
    /// 使い分けは `VoiceGuidance` と同じ話）。
    private var handedOverSignature: Int?
    /// 各 step を走っているあいだの道路名。`routeManeuvers` と同じ添字で並べる。
    /// 経路を組み立てるときに 1 度だけ作る（step が変わるたびに拾い直さない）。
    private var routeRoadNames: [[String]] = []
    /// 背面のときのバナーへ、最後に通した指示と距離の表記。**同じ文字を出し直させない**
    /// ための記録で、画面に出ているものとは別（前面ではバナーそのものが出ない）。
    private var notifiedManeuver: ObjectIdentifier?
    private var notifiedDistanceText: String?

    /// 車へ経路を渡す係（iOS 26.4 以降）。
    ///
    /// 型が 26.4 でしか存在せず、**格納プロパティには `@available` を付けられない**ので、
    /// `AnyObject` で持って `routeSharing` から取り出す。
    private var routeSharingBox: AnyObject?
    private var cancellables = Set<AnyCancellable>()

    /// パンボタンを押し続けているあいだ地図を送り続ける時計。**押しているあいだ CarPlay は
    /// 何も送ってこない**（開始と終了だけ）ので、無いとノブしか無い車で押し続けても地図が動かない。
    private var sustainedPanTimer: Timer?
    /// 送る間隔と 1 回ぶんの量。掛けると毎秒 240pt で、瞬間押し（100pt）を続けるより少し速い。
    private static let sustainedPanInterval: TimeInterval = 0.1
    private static let sustainedPanStep: CGFloat = 24

    /// 指を離したあとの惰性。**指が離れたあとも CarPlay は何も送ってこない**ので、
    /// 押しっぱなしのパンと同じく最後の速度から自分で送り続ける。無いと地図が指の下で
    /// ぴたりと止まり、放り投げて先を見るという地図アプリの手触りがそのまま消える。
    private var glideLink: CADisplayLink?
    private var glideVelocity: CGPoint = .zero
    private var glideMoved: CLLocationDistance = 0
    /// 1 ミリ秒あたりの減衰率。`UIScrollView.DecelerationRate.normal` と同じ値にしてある。
    private static let glideDecay: CGFloat = 0.998
    /// これを下回ったら止める（pt/秒）。
    private static let glideCutoff: CGFloat = 24

    /// 直前に反映した段階。**同じ段階が出し直されたときに中心へ戻さない**ための記録。
    /// リルートが成功すると `NavigationController.startNavigation(with:)` を通って
    /// `phase` は `.navigating` のまま経路だけ入れ替わる。見分けないと、地図を動かして
    /// 先を眺めているあいだにリルートのたびに自車へ引き戻される。
    private var lastPhaseKind: PhaseKind?

    /// 段階の中身を落として種類だけにしたもの。`Phase` に `Equatable` を足すと
    /// `NavRoute` まで比較の対象になるので、こちらで畳む。
    private enum PhaseKind {
        case idle, calculating, previewing, navigating

        init(_ phase: NavigationController.Phase) {
            switch phase {
            case .idle: self = .idle
            case .calculating: self = .calculating
            case .previewing: self = .previewing
            case .navigating: self = .navigating
            }
        }
    }

    @available(iOS 26.4, *)
    private var routeSharing: CarPlayRouteSharing? { routeSharingBox as? CarPlayRouteSharing }

    /// 案内中に経路が入れ替わった理由。`CPRerouteReason`（iOS 26.4）へ変換して車へ渡す。
    /// `CPRerouteReason` をそのまま持ち回ると、26.0 でも通る場所に 26.4 の型が漏れる。
    ///
    /// **`Core/` の同名の enum とは別物。** あちらは読み上げの最初のひと言を決めるもので、
    /// 「止めていたものを戻しただけ」に相当する case を持たない。読み替えは
    /// [init(_:)] にまとめてある。
    private enum RouteChangeReason {
        /// 経路を外れたので引き直した。
        case offRoute
        /// 立ち寄り先が増減した。
        case waypointChanged
        /// 利用者が選んで別の道へ切り替えた（渋滞の迂回）。
        case alternate
        /// 止めていたものを戻しただけで、**経路は変わっていない**（経路に乗った）。
        case resumed

        /// `Core/` 側の理由からの読み替え。
        ///
        /// **`.waypointChanged` で固定しないこと。** 渋滞の迂回を受け入れたときに
        /// 「経由地が変わった」と車へ言うことになり、先進運転支援を積んだ車は
        /// その前提で経路の変更を解釈する（経由地は 1 つも変わっていない）。
        ///
        /// `.started` は本来ここへ来ない（前の経路が無ければ渡し直しにならない）。
        /// 来たとしても**何も言わない側**に倒しておく。
        init(_ reason: CoreRouteChangeReason) {
            switch reason {
            case .started: self = .resumed
            case .rerouted: self = .offRoute
            case .waypointAdded: self = .waypointChanged
            case .switched: self = .alternate
            }
        }

        @available(iOS 26.4, *)
        var carPlayReason: CPRerouteReason {
            switch self {
            case .offRoute: .missedTurn
            case .waypointChanged: .waypointModified
            case .alternate: .alternateRoute
            case .resumed: .unknown
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
        // 追従が入り切りしたら、その枠のボタンを現在地 ⇄ パンで貼り替える。
        mapViewController.onFollowingChanged = { [weak self] _ in self?.refreshMapButtons() }

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
            onCommand: { [weak self] in self?.perform($0) },
            onError: { [weak self] in self?.presentAlert(message: $0) })

        mapTemplate.mapDelegate = self
        mapTemplate.automaticallyHidesNavigationBar = false
        // **既定に任せると案内カードが赤く出る**（2026-08-16 に実車の CarPlay で実測）。
        // 色を渡す口は 3 つあり、`CPManeuver.cardBackgroundColor` → これ → CarPlay の既定、
        // の順に優先される。前 2 つを渡していないのに赤いので、赤は既定そのもの。
        // 曲がる指示は警告ではないので、経路の線と同じ青に揃える。
        // 渡した色は `pauseTrip` のカードにも波及するため、あちらは色を明示して切り離す
        // （[replaceRoute] と [refreshTripPause]）。
        mapTemplate.guidanceBackgroundColor = .systemBlue
        applyIdleButtons()
        interfaceController.setRootTemplate(mapTemplate, animated: true, completion: nil)

        location.requestAuthorization()
        location.startUpdating()
        observeState()
    }

    /// 背面のときに出たバナーを押して、この画面へ戻ってきた。
    ///
    /// **地図を自車へ戻す。** 押した人は「いまの案内を見せろ」と言っているのに、
    /// 前に指で動かしたままだと別の場所を映した地図に着地する。
    ///
    /// **「追従へ勝手に戻さない」の例外**（`recenter()` の説明）にあたるが、これは
    /// こちらの都合で戻すのではなく、現在地ボタンと同じ**利用者が押した結果**。
    func bannerSelected() {
        recenterMap("banner")
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
        // 押しっぱなし・惰性の途中でシーンが切れることがある。どちらも `self` を
        // 掴んでいるので必ず止める。
        stopSustainedPan()
        stopGlide()
        clearSession()
    }

    /// セッションまわりの持ち物を一度に捨てる。終了・中止・シーン切断で通る道が
    /// 4 本あり、片方だけ足し忘れると次の案内に前回の残骸が混ざる。
    private func clearSession() {
        navigationSession = nil
        currentTrip = nil
        activeManeuver = nil
        routeManeuvers = []
        routeRoadNames = []
        maneuverRouteID = nil
        handedOverSignature = nil
        routeSharingBox = nil
        pauseReason = nil
        notifiedManeuver = nil
        notifiedDistanceText = nil
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

        // **流れてきた値をそのまま渡す。** `@Published` は `willSet` で流れるので、
        // ここで `navigation.isRerouting` を読み直すと必ず 1 つ前の値になる
        // （`NavigationController` が `lastRouteChange` を `phase` より先に置いて
        // いるのと同じ話）。読み直すと、立ち上がりでも立ち下がりでも判断が
        // 1 つずれて `pauseTrip` / `resumeTrip` が出そこねる。
        navigation.$isRerouting
            .removeDuplicates()
            .sink { [weak self] isRerouting in
                guard let self else { return }
                // `progress` は自分の `willSet` の外なので、こちらは読んでよい。
                refreshTripPause(isRerouting: isRerouting, progress: navigation.progress)
            }
            .store(in: &cancellables)

        navigation.arrived
            .sink { [weak self] _ in self?.finishSession() }
            .store(in: &cancellables)

        navigation.$lastError
            .compactMap { $0 }
            .sink { [weak self] in self?.presentAlert(message: $0) }
            .store(in: &cancellables)

        RestReminder.shared.suggestion
            .sink { [weak self] in self?.presentRestSuggestion() }
            .store(in: &cancellables)

        RangeAdvisor.shared.advice
            .sink { [weak self] in self?.presentRangeAdvice($0) }
            .store(in: &cancellables)

        RouteWeather.shared.hazard
            .sink { [weak self] in self?.presentWeatherHazard($0) }
            .store(in: &cancellables)

        ParkingAdvisor.shared.advice
            .sink { [weak self] in self?.presentParkingAdvice($0) }
            .store(in: &cancellables)

        TrafficAdvisor.shared.advice
            .sink { [weak self] in self?.presentTrafficAdvice($0) }
            .store(in: &cancellables)

        navigation.rerouteBlockedOffline
            .sink { [weak self] in self?.presentOfflineNotice() }
            .store(in: &cancellables)
    }

    // MARK: - 状態の反映

    private func apply(phase: NavigationController.Phase) {
        // **段階そのものが変わったときだけ**中心へ戻す。同じ段階の出し直し（リルートの
        // 完了が代表）で戻すと、地図を動かして先を眺めているあいだに引き戻される。
        // 追従へ戻す道は現在地ボタンとパン UI の「完了」に残してある。
        let kind = PhaseKind(phase)
        let entered = lastPhaseKind != kind
        lastPhaseKind = kind

        // **案内から出たら、セッションと `CPTrip` は必ず捨てる。**
        //
        // iPhone の画面と Siri は `NavigationController.cancelNavigation()` を直に呼ぶので、
        // CarPlay 側の案内終了ボタンと違って `cancelSession()` を通らない。畳まないと
        // `pauseTrip` のカードが待機画面に残り、進捗も経路も流れてこないので二度と下ろせない。
        //
        // **`.idle` だけでは足りない。** 案内中に目的地を変えると
        // `.navigating` → `.calculating` → `.previewing` → `.navigating` と回って
        // **`.idle` を一度も通らない**（マイク・「目的地を変更」・車からの目的地の 3 経路）。
        // `beginSessionIfNeeded` は二重開始ガードで早期に返るため、車は前の目的地の
        // `CPTrip` を掴んだまま走り切ることになる（`CPNavigationSession.trip` と
        // `CPTrip.destinationWaypoint` は読み取り専用なので、あとから直せない）。
        // しかも `showTripPreview` が `currentTrip` を新しい行き先で上書きするので、
        // 毎秒の `mapTemplate.update(_:for:with:)` はセッションを持たない `CPTrip` を
        // 宛先にし、到着予定と色が更新されなくなる。
        //
        // **`navigationSession != nil` で囲わない。** 捨てたルート提示の `currentTrip` は
        // セッションを持たないまま残り、`.previewing` を通らない次の入口
        // （Dashboard・Siri・「ここに停める」）がそれを拾って案内を始めてしまう。
        // `cancelSession()` は nil 安全で冪等。
        if kind != .navigating { cancelSession() }

        switch phase {
        case .idle:
            previewedRoute = nil
            mapTemplate.hideTripPreviews()
            mapViewController.show(route: nil)
            if entered { recenterMap("idle") }
            applyButtons(for: .idle)

        case .calculating:
            // ルート計算中は行き先ピンだけ消しておく。テンプレートは触らない。
            mapViewController.show(route: nil)

        case let .previewing(routes):
            guard let first = routes.first else { return }
            previewedRoute = first
            mapViewController.show(route: first)
            mapViewController.showRouteOverview(first)
            applyButtons(for: .previewing)
            showTripPreview(for: routes)

        case let .navigating(route):
            previewedRoute = nil
            mapTemplate.hideTripPreviews()
            mapViewController.show(route: route)
            if entered { recenterMap("navigating") }
            applyButtons(for: .navigating)
            beginSessionIfNeeded(for: route)
        }
    }

    /// 追従へ戻す。**惰性も一緒に止める**（止めないと、戻した直後も地図が流れ続けて
    /// 次の位置更新まで自車から離れていく）。
    ///
    /// **ここは指が触れている最中にも通る**。`recenter()` が進行中の回転・傾けの基準を
    /// 捨てるので、必ずログを残す。残さないとジェスチャの行だけを見ても
    /// 「急に効かなくなった」理由が読めない。
    private func recenterMap(_ reason: String) {
        stopGlide()
        mapViewController.recenter()
        CarPlayGestureLog.camera("recenter(\(reason))", camera: mapViewController.cameraState())
    }

    private func apply(progress: RouteProgress) {
        guard let trip = currentTrip, let route = navigation.currentRoute else { return }

        // **止めるかどうかを先に決める。** ここは `$progress` の sink の中なので
        // `navigation.progress` はまだ 1 つ前の値。**受け取った `progress` を渡す**
        // （読み直すと、経路に乗ったかの判断が毎回 1 測位ぶん遅れる）。
        // 先に呼ぶのは、再開したときに `activeManeuver` が差し替わるため。
        // 下の見積もりは差し替わったあとのものへ渡したい。
        refreshTripPause(isRerouting: navigation.isRerouting, progress: progress)

        // 残り時間の色で、見込みからどれだけ遅れているかを示す（`TrafficCondition`）。
        // **測り直すまでは `.default`**。3 分おきの測り直しが 1 度も走っていないうちに
        // 色を出すと、根拠の無い緑を出発直後に見せることになる。
        mapTemplate.update(CPTravelEstimates(distanceRemaining: .meters(progress.distanceRemaining),
                                             timeRemaining: progress.timeRemaining),
                           for: trip,
                           with: navigation.trafficCondition?.timeRemainingColor ?? .default)

        if let activeManeuver {
            let timeToManeuver = estimatedTime(forDistance: progress.distanceToNextManeuver, on: route)
            navigationSession?.updateEstimates(
                CPTravelEstimates(distanceRemaining: .meters(progress.distanceToNextManeuver),
                                  timeRemaining: timeToManeuver),
                for: activeManeuver)
            send(maneuverState: maneuverState(forDistance: progress.distanceToNextManeuver))
        }
    }

    // MARK: - ルート提示

    private func showTripPreview(for routes: [NavRoute]) {
        let trip = makeTrip(for: routes)
        currentTrip = trip

        let configuration = CPTripPreviewTextConfiguration(startButtonTitle: String(localized: "案内開始"),
                                                           additionalRoutesButtonTitle: String(localized: "他のルート"),
                                                           overviewButtonTitle: String(localized: "全体表示"))
        mapTemplate.showTripPreviews([trip], textConfiguration: configuration)
    }

    /// 候補ルートすべてを 1 つの `CPTrip` にまとめる。
    /// CarPlay ではこうすると「他のルート」で切り替えられる。
    private func makeTrip(for routes: [NavRoute]) -> CPTrip {
        // 数字だけでは候補の違いが読み取れないので、比較して分かる特徴を添える。
        let characters = RouteCharacter.tags(for: routes)

        let choices = routes.enumerated().map { index, route -> CPRouteChoice in
            let summary = Formatters.routeSummary(distance: route.distance, duration: route.expectedTravelTime)
            // 特徴と、有料道路・通行規制などの注意を要約に足す。variants は
            // 「入るなら長い方」を選ぶ仕組みなので、幅の狭い車では自動的に短い表記へ落ちる。
            let extras = characters[index] + route.advisoryNotices
            let variants = extras.isEmpty
                ? [summary]
                : ["\(summary)・\(extras.joined(separator: "、"))", summary]

            let choice = CPRouteChoice(summaryVariants: [route.name.isEmpty ? String(localized: "ルート") : route.name],
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
                              name: String(localized: "現在地")),
                          destinationWaypoint: CarPlayRouteSharing.waypoint(for: route.destination),
                          routeChoices: choices)
        } else {
            trip = CPTrip(origin: MKMapItem.forCurrentLocation(),
                          destination: route.destination.mapItem,
                          routeChoices: choices)
        }

        // **目的地名は必ず渡す**（ヘッダが「1 件以上」と要求している）。案内カードや
        // メーターに出る名前がここから来る。名前を持たない地点（座標だけの履歴）が
        // あるので、空なら言葉で埋める。
        let name = route.destination.name
        trip.destinationNameVariants = [name.isEmpty ? String(localized: "目的地") : name]
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
        handedOverSignature = route.signature

        // 経路の区間を積むのは maneuver を組み終えたあと。区間の中に入れる `CPManeuver` は
        // `routeManeuvers` と同じインスタンスでなければならない。
        if #available(iOS 26.4, *) {
            let sharing = CarPlayRouteSharing()
            routeSharingBox = sharing
            sharing.begin(session: session,
                          route: route,
                          maneuvers: routeManeuvers,
                          stepIndex: stepIndex,
                          tripEstimates: tripEstimates(for: route, progress: navigation.progress))
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

    /// 案内カードを止めるかどうかを決め直す。**止める事情はいまのところ 2 つ**あり、
    /// どちらも「案内は続いているが、いまの指示に従える状態ではない」を表す。
    ///
    /// 経路を張り替えるのではなく、同じ `CPNavigationSession` を一時停止して、
    /// 新しい経路の情報を渡して再開する。セッションを作り直すと `CPTrip` から
    /// 組み直しになり、到着予定の表示が一度途切れる。
    ///
    /// **理由は 1 つしか出せないので順番を決めてある。** 引き直し中は「経路へ進む」より
    /// 「再検索中」のほうが先で、引き直しが終わればまだ乗っていない側が残る。
    ///
    /// 呼ぶのは 3 か所。`$progress`、`$isRerouting`、それに経路を渡し直したあとの
    /// [replaceRoute]。**どこから来ても desired が変わらなければ何もしない**ので、
    /// 毎秒呼ばれても `pauseTrip` は飛ばない。
    ///
    /// **判断の材料は必ず引数で受ける。** 前の 2 つはその `@Published` 自身の sink の中に
    /// いて、`@Published` は `willSet` で流れる。プロパティを読み直すと 1 つ前の値しか
    /// 取れず、`pauseTrip` も `resumeTrip` も出そこねる。`replaceRoute` からの道だけは
    /// `maneuverChanged`（`PassthroughSubject`）の中なので値が確定しているが、
    /// **あちらは `pauseReason` を書き換えた直後に再入する**ので、引数で揃えておくほうが
    /// 読み違えない。
    private func refreshTripPause(isRerouting: Bool, progress: RouteProgress?) {
        guard let navigationSession else { return }

        let desired: TripPause?
        if isRerouting {
            desired = .rerouting
        } else if progress?.hasJoinedRoute == false {
            // **進捗が無いうちは止めない。** 測位が来る前に「経路へ進む」を出すと、
            // 経路の上から始めた場合でも一瞬そう見える。
            desired = .proceedToRoute
        } else {
            desired = nil
        }
        guard desired != pauseReason else { return }

        let previous = pauseReason

        // **`.rerouting` から出るなら、止め直すだけの場合でも先に渡し直す。**
        // 引き直しが成功していれば経路は入れ替わっているのに、`resumeTrip` を通るのは
        // この `resume` だけ。止めたまま理由を差し替えると、新しい経路が車へ一度も
        // 渡らず、ルート共有の区間も捨てた経路のまま固まる（`routeID` が食い違うので
        // 以降 `updateCurrentSegment` も通らなくなる）。ガイド p.61 の「止めてから
        // 渡し直す」は、止めっぱなしで理由だけ変わる場合にも要るということ。
        if desired == nil || previous == .rerouting {
            // **理由は「引き直し中だったか」ではなく、経路が本当に入れ替わったかで決める。**
            // 圏外と停車では引き直しを見送りつつ `isRerouting` を下ろす（どちらも
            // 「検索していないのに再検索中のカードが残る」を避けるため）ので、
            // **経路をまったく計算していないのに `.rerouting` から出てくる道がある**。
            // そこで `.missedTurn` を渡すと、経路を外れた場所で信号待ちするたびに
            // まったく同じ経路を「外れたから引き直した」として車へ送り、26.4 では
            // 区間ごと組み直させることになる。
            let changed = navigation.currentRoute.map { $0.signature != handedOverSignature } ?? false
            let reason: RouteChangeReason = changed ? .offRoute : .resumed
            if !resume(navigationSession, reason: reason, progress: progress) {
                // **渡し直せなかった。** 記録を進めてよいのは「止めたままで理由だけ
                // 変わる」場合だけ。そこで諦めると、検索していないのに「再検索中」の
                // カードが残ったうえ、`updateManeuvers` の渡し直しも
                // `pauseReason != .rerouting` で閉じたままになり、車は新しい経路を
                // 一度も受け取れない（`CPNavigationAlert` にも `NavigationLog` にも
                // 何も出ないので、直したはずのバグと区別が付かなくなる）。
                //
                // 止めるのをやめる側（`desired == nil`）では進めてはいけない。実際は
                // 止まったままなのに「止めていない」ことになり、以降 desired が一致して
                // オレンジのカードがその案内のあいだ固着する。次の測位でまたここへ来る。
                guard desired != nil else { return }
            }
        }

        pauseReason = desired
        switch desired {
        case .rerouting:
            // description に nil を渡すと CarPlay 側の既定文言（英語環境なら英語）になる。
            // 他の画面の文言に合わせて日本語で出す。
            navigationSession.pauseTrip(for: .rerouting,
                                        description: String(localized: "ルートを再検索中"),
                                        turnCardColor: Self.pausedCardColor)
        case .proceedToRoute:
            // **駐車場や施設の中から案内を始めたとき。** MapKit は経路の始点を最寄りの
            // 車道へ寄せるので、動き出すまで数百メートル外に居ることがある。そこを逸脱と
            // して引き直さないのは `GuidanceEngine` の判断（引き直しても始点は同じ車道へ
            // 寄るので何も変わらない）だが、**黙っていると普通の案内カードが出たまま**で、
            // 「この指示はいつから有効なのか」が分からない。
            navigationSession.pauseTrip(for: .proceedToRoute,
                                        description: String(localized: "経路へ進んでください"),
                                        turnCardColor: Self.pausedCardColor)
        case nil:
            break // 上で渡し直し済み。
        }
    }

    /// 案内中に経路そのものが入れ替わったことを CarPlay と車へ伝える。
    ///
    /// 通るのは**利用者の操作で経路が入れ替わったとき**——立ち寄り先の追加と、渋滞の
    /// 迂回を受け入れたとき。逸脱による引き直しは `refreshTripPause` が止めるところと
    /// 再開するところの両方を担うので、そちらでは呼ばない。
    ///
    /// **素通しで `resumeTrip` を投げないこと。** 経路を変えるときは一度 `pauseTrip` で
    /// 止めてから渡し直す、というのがガイド p.61 の手順で、止めずに渡すと車側が
    /// 前の経路を掴んだままになる。
    private func replaceRoute(reason: RouteChangeReason) {
        guard let navigationSession else { return }

        // **すでに止まっているなら重ねて止めない。** 理由は違っても「渡し直す前に
        // 止まっている」という p.61 の条件は満たしている。出し直すと、止めている
        // 理由が一瞬だけ引き直しに化けて見える（「経路へ進む」の最中に立ち寄り先を
        // 足したときがこれにあたる）。
        if pauseReason == nil {
            navigationSession.pauseTrip(for: .rerouting,
                                        description: String(localized: "ルートを引き直し中"),
                                        turnCardColor: Self.pausedCardColor)
            pauseReason = .rerouting
        }
        // ここは `maneuverChanged` の中なので `progress` は確定済み。読んでよい。
        guard resume(navigationSession, reason: reason, progress: navigation.progress) else { return }
        pauseReason = nil

        // **止める事情が残っていれば出し直す。** 渡し直しは 1 往復で終わるが、
        // まだ経路に乗っていないという事情はそれで消えるものではない。
        refreshTripPause(isRerouting: navigation.isRerouting, progress: navigation.progress)
    }

    /// 止まっているあいだのカードの色。
    ///
    /// **`guidanceBackgroundColor` と分けてある**。渡さないと `pauseTrip` のカードは
    /// 案内カードと同じ青になり、「いま案内が止まっている」ことが文言でしか分からなくなる。
    /// 赤にはしない。引き直しは危険でも失敗でもなく、待てば戻るものなので。
    private static let pausedCardColor = UIColor.systemOrange

    /// 引き直した経路で案内を再開する。
    ///
    /// iOS 26.4 からは**経由地ごとに区切った `CPRouteSegment` の配列**で渡す形になり、
    /// 17.4 からの `CPRouteInformation` は非推奨になった（26.0 が下限のうちは警告は出ない）。
    /// 新しい方に寄せているのは経由地の表現力のためではなく、**ルート共有が
    /// そちらでしか成立しない**ため。車へ経路を預けるには区間を積んでおく必要がある。
    /// 26.0〜26.3 では区間を作れないので、古い方をそのまま残してある。
    ///
    /// **`routeManeuvers` がいまの経路のものか照合してから渡す。** `NavigationController`
    /// は `progress` を `maneuverChanged` より先に流すので、進捗から呼ばれるこの道には
    /// 「経路はもう新しいのに `CPManeuver` はまだ古い」という一瞬が必ずある。そこで
    /// 渡すと、新しい座標列に捨てた経路の指示を詰めた区間を車へ送ることになる
    /// （`stepCount` の `min` がクラッシュは防ぐが、黙って切り詰めるだけ）。
    ///
    /// 渡せなかったことを呼び元が知る必要があるので `Bool` を返す。止めた記録を
    /// 進めてよいかがこれで決まる。
    private func resume(_ session: CPNavigationSession,
                        reason: RouteChangeReason,
                        progress: RouteProgress?) -> Bool {
        guard let route = navigation.currentRoute,
              !routeManeuvers.isEmpty,
              maneuverRouteID == route.id else { return false }
        let stepIndex = min(progress?.stepIndex ?? 0, routeManeuvers.count - 1)
        let upcoming = Array(routeManeuvers[stepIndex...].prefix(2))
        let estimates = tripEstimates(for: route, progress: progress)

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
        // 車が持っている経路をここで控える。次に渡し直すときの理由（外れたのか、
        // 止めていたものを戻すだけなのか）はこれと比べて決める。
        handedOverSignature = route.signature
        return true
    }

    /// 目的地までの残りの見積もり。進捗が出ていなければ経路全体の値を使う。
    ///
    /// **進捗は引数で受ける。** `@Published` の sink の中から呼ばれる道があり、
    /// そこで `navigation.progress` を読むと 1 測位ぶん古い数字を車へ渡すことになる。
    private func tripEstimates(for route: NavRoute, progress: RouteProgress?) -> CPTravelEstimates {
        CPTravelEstimates(
            distanceRemaining: .meters(progress?.distanceRemaining ?? route.distance),
            timeRemaining: progress?.timeRemaining ?? route.expectedTravelTime)
    }

    // MARK: - 案内カード

    private func updateManeuvers(route: NavRoute, stepIndex: Int) {
        if maneuverRouteID == route.id {
            showManeuvers(from: stepIndex)
        } else {
            // 経路が入れ替わった。作り直して渡し直す。
            let hadRoute = maneuverRouteID != nil
            rebuildManeuvers(for: route, stepIndex: stepIndex, isNewSession: false)

            // 逸脱による引き直しなら、止めたのも再開するのも `refreshTripPause` の
            // 仕事なので触らない。**見るのは「止まっているか」ではなく「引き直し中か」**。
            // 「経路へ進む」で止めているあいだに立ち寄り先が増えることはあり、
            // そのときは渡し直しが要る。
            //
            // **理由は `NavigationController` から受け取る。** ここを通るのは立ち寄り先の
            // 追加と、渋滞の迂回を利用者が受け入れたときの 2 つで、後者では経由地が
            // 1 つも変わっていない。`lastRouteChange` は `phase` より先に置かれるので、
            // `maneuverChanged` が流れる時点でもう新しい値。
            if hadRoute, pauseReason != .rerouting {
                replaceRoute(reason: RouteChangeReason(navigation.lastRouteChange))
            }
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
                         at: index,
                         on: route,
                         distance: index == stepIndex ? currentDistanceToManeuver(default: step.distance) : step.distance)
        }
        maneuverRouteID = route.id
        routeRoadNames = Self.roadNames(on: route)

        if isNewSession { navigationSession?.add(routeManeuvers) }
        showManeuvers(from: stepIndex)
    }

    /// 各 step を走っているあいだの道路名を、経路 1 本ぶんまとめて拾う。
    ///
    /// **見るのは 1 つ前の step の指示文。** この作りでは `steps[i].instruction` が
    /// **step i の終わりで行う操作**（「国道156号を右方向」）なので、いま走っている道は
    /// **ひとつ前の操作で入った道**になる。`roadFollowingManeuverVariants` に渡すものを
    /// 1 つずらして並べ直しているだけで、拾い方（`RoadName`）は同じ。
    ///
    /// **最初の step だけは空になる。** 出発地の道を教えてくれる指示文が無く、
    /// `MKRoute.name` は経路全体の代表名（先の高速道路の名前が入ることがある）なので、
    /// いま走っている道として渡すと嘘になる。
    private static func roadNames(on route: NavRoute) -> [[String]] {
        route.steps.indices.map { index in
            guard index > 0,
                  let name = RoadName.first(in: route.steps[index - 1].instruction) else { return [] }
            return [name]
        }
    }

    /// 次の指示（と、その次）を CarPlay の案内カードに載せる。
    /// CarPlay は 2 件までしか表示しないので 2 件で切る。
    private func showManeuvers(from stepIndex: Int) {
        guard routeManeuvers.indices.contains(stepIndex) else { return }

        let upcoming = Array(routeManeuvers[stepIndex...].prefix(2))
        navigationSession?.upcomingManeuvers = upcoming
        // いま走っている道の名前。**車のメーター・HUD にしか出ない。**
        // 拾えなかった step では空にする（前の道の名前を残すと、曲がったあとも
        // ひとつ前の道を走っていることになる）。
        navigationSession?.currentRoadNameVariants = routeRoadNames.indices.contains(stepIndex)
            ? routeRoadNames[stepIndex]
            : []
        // 指示が切り替わった直後であることを車へ伝える。
        // 以降は距離に応じて apply(progress:) が prepare / execute へ進める。
        // 止めているあいだは `send(maneuverState:)` が丸める（そこの説明を参照）。
        send(maneuverState: .initial)
        activeManeuver = upcoming.first

        // 区間をまたいだかを見る。経由地を通過した瞬間がこれにあたる。
        // 経路が入れ替わった直後はまだ区間が古いので、どの経路のものかを渡して弾かせる。
        if #available(iOS 26.4, *), let navigationSession, let maneuverRouteID {
            routeSharing?.updateCurrentSegment(session: navigationSession,
                                               routeID: maneuverRouteID,
                                               stepIndex: stepIndex)
        }
    }

    /// 指示文の道路番号を標識の画像に差し替えた文。番号が無ければ nil。
    ///
    /// 添付できるのは**テキストアタッチメントだけ**で、ほかの属性は CarPlay が剥がす
    /// （ヘッダに明記）。色や字体を付けても消えるので、渡すのは画像 1 つに絞る。
    private func attributedInstruction(for instruction: String) -> NSAttributedString? {
        guard let found = RoadNumber.first(in: instruction),
              let image = RoadShieldImage.make(for: found.road) else { return nil }

        let attachment = NSTextAttachment()
        attachment.image = image
        // 行の中で下がって見えないよう、少しだけ持ち上げる。
        attachment.bounds = CGRect(x: 0, y: -4, width: image.size.width, height: image.size.height)

        let result = NSMutableAttributedString(string: String(instruction[..<found.range.lowerBound]))
        result.append(NSAttributedString(attachment: attachment))
        result.append(NSAttributedString(string: String(instruction[found.range.upperBound...])))
        return result
    }

    private func makeManeuver(for step: NavStep,
                              at stepIndex: Int,
                              on route: NavRoute,
                              distance: CLLocationDistance) -> CPManeuver {
        let kind = ManeuverKind.inferred(from: step.instruction)

        let maneuver = CPManeuver()
        // 交差点の形を 1 度だけ測って、**絵と角度の両方をここから作る**。別々に測ると、
        // 案内カードの図と車の HUD が食い違って出る余地ができる。
        let junction = JunctionGeometry.make(for: route, stepIndex: stepIndex)
        // 交差点の拡大図。MapKit は交差点のデータを返さないので、経路そのものの形を
        // 曲がる地点のまわりだけ拡大して描く。曲がらない指示では nil が返る。
        // **Dashboard 用は渡さない。** 指定しなければ CarPlay がこれを使う。
        maneuver.junctionImage = junction.flatMap {
            JunctionImage.make(for: $0, direction: kind.direction)
        }
        apply(junction: junction, direction: kind.direction, to: maneuver)
        // **候補は「長い順」に並べる。** CarPlay は先頭から見て**入るものを選ぶ**ので、
        // 1 件しか渡さないと入らなかったときに省略される。地名と道路名を落とした
        // 短縮形を後ろに置いておけば、狭い画面でも向きだけは必ず残る。
        let short = kind.direction.shortInstruction
        maneuver.instructionVariants = [step.instruction, short].compactMap { $0 }
        // Dashboard と通知バナーは案内カードよりさらに狭いので、**短いほうを先に**する。
        // 渡さなければ `instructionVariants` に落ちるだけなので、短縮形が作れないとき
        // （向きが読めなかったとき）は触らない。
        if let short {
            maneuver.dashboardInstructionVariants = [short, step.instruction]
            maneuver.notificationInstructionVariants = [short, step.instruction]
        }
        // 道路番号を標識の画像に差し替える（「国道156号を右方向」→「[156] を右方向」）。
        //
        // **見つかったときだけ渡す。** `attributedInstructionVariants` は
        // `instructionVariants` より優先されるので、常に渡すと上の短縮形の落とし先が
        // 効かなくなる。短縮形のぶんも同じ配列に入れて並びを保つ。
        if let attributed = attributedInstruction(for: step.instruction) {
            maneuver.attributedInstructionVariants = [attributed]
                + [short].compactMap { $0 }.map { NSAttributedString(string: $0) }
        }
        maneuver.symbolImage = kind.image
        // 画面のアイコンだけでなく、車のメーター・HUD へもこの型で送られる。
        maneuver.maneuverType = kind.type
        // ロータリーの回り方に効く。既定は右側通行なので、渡さないと日本では逆に描かれる。
        maneuver.trafficSide = DrivingSideLocator.shared.current.carPlaySide
        // 曲がった先の道路名。**車のメーター・HUD 側にしか出ない**（案内カードには
        // 指示文がそのまま出る）ので、拾えなければ渡さないだけでよい。
        // 裏返すと**こちらの画面をいくら見ても当たっているか分からない**ので、
        // 拾えた・拾えなかったの両方をログに残す。
        let road = RoadName.first(in: step.instruction)
        if let road { maneuver.roadFollowingManeuverVariants = [road] }
        CarPlayVehicleLog.roadName(road, from: step.instruction)
        // **距離と時間は同じ値から出す。** `distance` は走っている区間だけ「残り」に
        // なる（`currentDistanceToManeuver`）ので、時間のほうを step 全体で出すと組が
        // 食い違う。首都高の 4172m の区間で出口の 200m 手前にいると「200m ＝ 5 分」に
        // なり、それが `CPRouteSegment.maneuverTravelEstimates` と `resumeTrip` から
        // そのまま車へ渡る（画面に出るのは `apply(progress:)` が整合させた値なので、
        // ここの食い違いはメーター・HUD とルート共有にしか出ない）。
        maneuver.initialTravelEstimates = CPTravelEstimates(
            distanceRemaining: .meters(distance),
            timeRemaining: estimatedTime(forDistance: distance, on: route))
        return maneuver
    }

    /// 交差点の種別と、出ていく向きを車へ渡す。
    ///
    /// **角度を渡すのはロータリーだけ。** ふつうの交差点は `maneuverType` と拡大図で
    /// 曲がる向きが伝わるので角度が足す情報が無く、いっぽうロータリーは「何番目の出口か」
    /// を送れていない（`ManeuverKind` は `.enterRoundabout` までしか出せない）ため、
    /// 角度がどちらへ抜けるかを伝える唯一の手段になる。
    ///
    /// **基準の取り方は推測を含む。** ヘッダは "the angle of the exit road" としか書いて
    /// おらず、何を 0 度とするかを決めていない。ここでは**進行方向を 0 度、時計回りを正**
    /// として [0, 360) に正規化している。案内カードの拡大図とまったく同じ測定
    /// （`JunctionGeometry`）から作っているので、**車が描く向きと画面の図はこの規約が
    /// 正しい限り一致する**。対応した車でしか確かめようがないので、送った値をログに残す。
    ///
    /// `junctionElementAngles`（通らない側の道）は渡さない。MapKit がそのデータを
    /// 返さないうえ、でっち上げると「そこに道がある」と車に言うことになる。
    private func apply(junction: JunctionGeometry?,
                       direction: ManeuverDirection,
                       to maneuver: CPManeuver) {
        guard direction == .roundabout else {
            maneuver.junctionType = .intersection
            return
        }
        maneuver.junctionType = .roundabout

        guard let junction else { return }
        let degrees = (junction.turn * 180 / .pi).truncatingRemainder(dividingBy: 360)
        let normalized = degrees < 0 ? degrees + 360 : degrees
        maneuver.junctionExitAngle = Measurement(value: normalized, unit: .degrees)
        CarPlayVehicleLog.roundabout(exitAngle: normalized)
    }

    /// 車のメーター・HUD へ段階を送る。**止めているあいだは `.continue` に丸める。**
    ///
    /// `GuidanceEngine` は現在地を経路へ吸着させるので、駐車場に停まったままでも
    /// 「次の曲がり角まで 100m」になりうる。そのまま送ると、カードが「経路へ進んで
    /// ください」と出している横で、メーターと HUD だけが「いま曲がれ」と言う。
    /// **引き直し中も同じ**で、あちらは吸着先そのものがもう捨てた経路（`NavigationController`
    /// は `progress` を代入したあとで逸脱を見るので、止めているあいだも毎秒ここへ来る）。
    ///
    /// **書き込む口をここ 1 つに絞ってあるのは、片方だけ丸めても気づけないから。**
    /// 距離から決める側（`apply(progress:)`）と、指示が入れ替わったことを伝える側
    /// （`showManeuvers`。止めているあいだも step の添字は進む）の 2 か所があり、
    /// **どちらも画面には出ない**ので、食い違いに気づけるのは車か `CarPlayVehicleLog` だけ。
    private func send(maneuverState state: CPManeuverState) {
        navigationSession?.maneuverState = pauseReason == nil ? state : .continue
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
    /// ルート提示中に選ばれている候補。詳細を出す対象。
    ///
    /// 候補を切り替えても `phase` は動かない（`.previewing` のまま）ので、
    /// `selectedPreviewFor` で追いかけないと、いつも先頭の詳細を出すことになる。
    private var previewedRoute: NavRoute?

    /// ルート提示中だけ「この経路について」を出す。
    ///
    /// **案内が始まったら入口ごと消える**（`applyNavigatingButtons` に無い）。
    /// 走行中に読ませる画面ではないし、案内中は左右とも枠が埋まっている。
    /// `destinationsButton` は端に残す。1 つだけのときと押す場所を変えないため。
    private func applyPreviewingButtons() {
        mapTemplate.mapButtons = idleMapButtons
        mapTemplate.leadingNavigationBarButtons = [voiceButton]
        mapTemplate.trailingNavigationBarButtons = [routeInfoButton, destinationsButton]
    }

    private var routeInfoButton: CPBarButton {
        CPBarButton(title: String(localized: "この経路について")) { [weak self] _ in
            self?.presentRouteInformation()
        }
    }

    /// 選ばれている候補の中身を出す。
    private func presentRouteInformation() {
        guard let route = previewedRoute ?? navigation.previewedRoutes.first else { return }
        let template = CarPlayRouteInformation.template(for: route) { [weak self] in
            self?.interfaceController.popToRootTemplate(animated: true, completion: nil)
            self?.navigation.startNavigation(with: route)
        }
        interfaceController.pushTemplate(template, animated: true, completion: nil)
    }

    /// 段階に合ったボタンを貼る。**段階が動いたときの入口はここだけにする。**
    ///
    /// **パン UI に入っているあいだは触らない。** あの画面から抜ける導線は
    /// `mapTemplateDidShowPanningInterface` が置く「完了」だけで
    /// （`dismissPanningInterface` の呼び元もそこ 1 か所）、`mapButtons` は CarPlay が
    /// 2 つに切り、`CPMapTemplate` は root テンプレートなので戻るボタンも無い。
    /// つまり差し替えた瞬間に**運転者がパン UI から出られなくなる**。
    /// ノブしか無い車では案内中に地図を動かす唯一の手段（ガイド p.33）なので、
    /// そこで閉じ込めるのがいちばん困る。
    ///
    /// 引き直しの完了（`.navigating` の出し直し）、iPhone・Siri からの中止（`.idle`）、
    /// 車が走り出す・止まるたびの `limitedUserInterfacesChanged` が、どれもパン中に届く。
    /// 抜けたときは `mapTemplateDidDismissPanningInterface` が貼り直す
    /// （**あちらは素の `apply*Buttons()` を呼ぶ**。ここを通すと、`isPanningInterfaceVisible`
    /// がまだ下りていなかった場合に二度と戻らなくなる）。
    private func applyButtons(for kind: PhaseKind) {
        guard !mapTemplate.isPanningInterfaceVisible else { return }
        switch kind {
        case .idle: applyIdleButtons()
        case .calculating: break // 計算中はテンプレートを触らない。
        case .previewing: applyPreviewingButtons()
        case .navigating: applyNavigatingButtons()
        }
    }

    private func applyIdleButtons() {
        mapTemplate.mapButtons = idleMapButtons
        mapTemplate.leadingNavigationBarButtons = [voiceButton]
        mapTemplate.trailingNavigationBarButtons = [destinationsButton]
    }

    /// 案内していないときは向きの切り替えを出さないぶん枠が余るので、現在地とパンを
    /// 両方置ける。案内中だけが分け合う（[followSlotButton]）。
    private var idleMapButtons: [CPMapButton] {
        [recenterButton, zoomInButton, zoomOutButton, panButton]
    }

    /// 向きの切り替えは案内中だけ出す。押す場所を変えないよう、並びは
    /// `applyIdleButtons` に揃えてある（先頭の枠だけは追従の状態で中身が入れ替わる。
    /// [followSlotButton]）。
    private func applyNavigatingButtons() {
        mapTemplate.mapButtons = navigatingMapButtons
        // ナビゲーションバーは左右 2 つずつが上限。マップボタンは 4 つで埋まっている
        // （しかもパン UI に入ると 2 つ落ちる）ので、音声はこちらへ置く。
        mapTemplate.leadingNavigationBarButtons = [voiceButton, overviewButton]
        mapTemplate.trailingNavigationBarButtons = [repeatButton, endNavigationButton]
    }

    private var navigatingMapButtons: [CPMapButton] {
        [followSlotButton, zoomInButton, zoomOutButton, orientationButton]
    }

    /// 現在地ボタンとパンボタンで分け合う枠。**追従しているあいだ現在地ボタンには
    /// 用が無い**（押しても何も変わらない）のでパンボタンを出し、地図を動かして
    /// 追従が外れたら現在地ボタンへ入れ替える。押す場所は動かさないので、
    /// 走行中に探し直さずに済む。この 1 枠が「いま追従しているか」の表示も兼ねる。
    ///
    /// 分け合っているのは案内中の 4 つが埋まっているため。**パン UI へ入るボタンは
    /// 外せない**（ガイド p.33。ノブしか無い車には他に地図を動かす手が無く、以前は
    /// 案内中にこれが落ちていて動かしようが無かった）ので、向きの切り替えを
    /// 落とすか分け合うかの二択になる。
    private var followSlotButton: CPMapButton {
        mapViewController.isFollowingUser ? panButton : recenterButton
    }

    /// 追従の入り切りに合わせてマップボタンを貼り直す。
    ///
    /// パン UI に入っているあいだは触らない。CarPlay が 2 つしか残さないので、
    /// その 2 つは `mapTemplateDidShowPanningInterface` が決めている。
    ///
    /// 段階を `navigation.phase` ではなく `lastPhaseKind` から見るのは、**`@Published` が
    /// `willSet` で流れる**ため。`apply(phase:)` の中から（`recenter()` 経由で）ここへ来た
    /// ときの `navigation.phase` はまだ 1 つ前の値で、案内へ入った瞬間に案内用の並びを
    /// 選べない。`lastPhaseKind` は `apply(phase:)` の先頭で更新済み。
    private func refreshMapButtons() {
        guard !mapTemplate.isPanningInterfaceVisible else { return }
        mapTemplate.mapButtons = lastPhaseKind == .navigating ? navigatingMapButtons : idleMapButtons
    }

    private func toggleMapOrientation() {
        MapOrientation.current = MapOrientation.current.toggled
        mapViewController.apply(orientation: MapOrientation.current)
        CarPlayGestureLog.camera("orientation(\(MapOrientation.current.rawValue))",
                                 camera: mapViewController.cameraState())
        // アイコンを新しい向きに差し替える。ナビゲーションバー側は変わらないので触らない。
        mapTemplate.mapButtons = navigatingMapButtons
    }

    private var destinationsButton: CPBarButton {
        CPBarButton(title: String(localized: "目的地")) { [weak self] _ in self?.destinations?.present() }
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
        CPBarButton(title: String(localized: "案内終了")) { [weak self] _ in
            self?.cancelSession()
            self?.navigation.cancelNavigation()
        }
    }

    /// いまの指示をもう一度読ませる。案内中だけ出す。
    /// 聞き逃しは走行中にいちばん起きることなのに、直す手段が無かった。
    private var repeatButton: CPBarButton {
        CPBarButton(image: UIImage(systemName: "speaker.wave.2.fill") ?? UIImage()) { _ in
            VoiceGuidance.shared.repeatCurrentGuidance()
        }
    }

    private var donePanningButton: CPBarButton {
        CPBarButton(title: String(localized: "完了")) { [weak self] _ in
            self?.mapTemplate.dismissPanningInterface(animated: true)
        }
    }

    private var overviewButton: CPBarButton {
        CPBarButton(title: String(localized: "全体表示")) { [weak self] _ in
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
        let button = CPMapButton { [weak self] _ in self?.recenterMap("button") }
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
        let button = CPMapButton { [weak self] _ in
            guard let self else { return }
            mapViewController.zoomIn()
            CarPlayGestureLog.camera("zoom in(button)", camera: mapViewController.cameraState())
        }
        button.image = UIImage(systemName: "plus.magnifyingglass")
        return button
    }

    private var zoomOutButton: CPMapButton {
        let button = CPMapButton { [weak self] _ in
            guard let self else { return }
            mapViewController.zoomOut()
            CarPlayGestureLog.camera("zoom out(button)", camera: mapViewController.cameraState())
        }
        button.image = UIImage(systemName: "minus.magnifyingglass")
        return button
    }

    // MARK: - 通知

    /// 声で言われたことを実行する。行き先は `onSelect` 側が受け持つので、ここには来ない。
    ///
    /// **どれもボタンでもできることに揃えてある。** 声でしかできない操作を作ると、
    /// 認識が外れたときに手段が無くなる。
    private func perform(_ command: VoiceCommand) {
        switch command {
        case .endNavigation:
            cancelSession()
            navigation.cancelNavigation()
        case .repeatGuidance:
            VoiceGuidance.shared.repeatCurrentGuidance()
        case .overview:
            guard let route = navigation.currentRoute else { return }
            mapViewController.showRouteOverview(route)
        case .destination:
            break
        }
    }

    /// 経路の先の天気。知らせるだけで、押させることは何も無い。
    private func presentWeatherHazard(_ hazard: RouteWeather.Hazard) {
        let alert = CPNavigationAlert(
            titleVariants: [hazard.message],
            subtitleVariants: nil,
            image: UIImage(systemName: hazard.symbolName),
            primaryAction: CPAlertAction(title: "OK", style: .default) { _ in },
            secondaryAction: nil,
            duration: 10)
        mapTemplate.present(navigationAlert: alert, animated: true)
    }

    /// 航続距離で届かないときの補給先の提案。
    ///
    /// 休憩の催促と同じく `CPNavigationAlert` で出す。ただしこちらは**押さないと
    /// 着けない**話なので、放置されたときのために表示を長めに取る。
    private func presentRangeAdvice(_ advice: RangeAdvisor.Advice) {
        let alert = CPNavigationAlert(
            titleVariants: [String(localized: "このままでは届きません")],
            subtitleVariants: [String(localized: "\(advice.place.name) に寄りますか")],
            image: UIImage(systemName: advice.kind == .evCharger ? "bolt.car.fill" : "fuelpump.fill"),
            primaryAction: CPAlertAction(title: String(localized: "寄る"), style: .default) { [weak self] _ in
                self?.navigation.addWaypoint(advice.place)
            },
            secondaryAction: CPAlertAction(title: String(localized: "いいえ"), style: .cancel) { _ in },
            duration: 20)
        mapTemplate.present(navigationAlert: alert, animated: true)
    }

    /// 圏外で経路を引き直せないことを知らせる。
    ///
    /// **黙って諦めない。** 引き直しを見送ると「再検索中」の赤いカードは下りるので、
    /// 何も出さないと**経路を外れたまま無反応**に見える（「再検索中が出っぱなし」を
    /// 直したつもりが「何も起きない」に変わるだけになる）。
    /// 押させることは何も無いので `CPNavigationAlert` で、放っておけば消える形にする。
    private func presentOfflineNotice() {
        let alert = CPNavigationAlert(
            titleVariants: [String(localized: "圏外のため経路を引き直せません")],
            subtitleVariants: [String(localized: "電波が戻ったら自動で引き直します")],
            image: UIImage(systemName: "wifi.slash"),
            primaryAction: CPAlertAction(title: "OK", style: .default) { _ in },
            secondaryAction: nil,
            duration: 10)
        mapTemplate.present(navigationAlert: alert, animated: true)
    }

    /// 走っている道より早い道が出てきたときの提案。
    ///
    /// **押されたときだけ切り替える。** 走行中に勝手に経路が入れ替わると音声も案内カードも
    /// 追随できない（`RoutePreferences` を変えても引き直さないのと同じ判断）。切り替えは
    /// `startNavigation(with:)` に任せる。すでに計算済みの経路なので引き直しは要らず、
    /// `CPNavigationSession` を張り替えずに繋ぐところは `updateManeuvers` が受け持つ。
    ///
    /// **押すまでに走った距離ぶんは織り込めない。** 渡す経路は測った時点の位置から
    /// 引いてあるので、間を置いて押されるとその先から始まる経路になる。同じ道の上に
    /// いるかぎり `GuidanceEngine` が吸着するので実害は出ず、外れていれば逸脱判定が
    /// 引き直す。
    private func presentTrafficAdvice(_ advice: TrafficAdvisor.Advice) {
        let arrival = Formatters.arrivalText(Date(timeIntervalSinceNow: advice.route.expectedTravelTime))
        let alert = CPNavigationAlert(
            titleVariants: [String(localized: "\(Formatters.durationText(advice.saving))早く着く道があります")],
            subtitleVariants: [String(localized: "\(arrival) 着になります")],
            image: UIImage(systemName: "arrow.triangle.branch"),
            primaryAction: CPAlertAction(title: String(localized: "切り替える"), style: .default) { [weak self] _ in
                self?.navigation.startNavigation(with: advice.route, reason: .switched)
            },
            secondaryAction: CPAlertAction(title: String(localized: "そのまま"), style: .cancel) { _ in },
            duration: 20)
        mapTemplate.present(navigationAlert: alert, animated: true)
    }

    /// 目的地の手前で出す駐車場の提案。
    ///
    /// **`addWaypoint` ではなく行き先そのものを差し替える。** 駐車場は寄ってから
    /// 目的地へ向かう場所ではなく、そこで降りる場所なので、経由地として挟むと
    /// 停めたあとも案内が目的地へ向かって続いてしまう。
    ///
    /// 提示を挟まない `startNavigation(to:)` を使うのは、Dashboard のショートカットと
    /// 同じ理由。押した時点で選び終わっているものを、走行中にもう一度選び直させない。
    private func presentParkingAdvice(_ advice: ParkingAdvisor.Advice) {
        let walking = Formatters.distanceText(advice.walkingDistance)
        let alert = CPNavigationAlert(
            titleVariants: [String(localized: "近くの駐車場")],
            subtitleVariants: [String(localized: "\(advice.place.name)・目的地まで徒歩 \(walking)")],
            image: UIImage(systemName: "parkingsign"),
            primaryAction: CPAlertAction(title: String(localized: "ここに停める"), style: .default) { [weak self] _ in
                self?.navigation.startNavigation(to: advice.place)
            },
            secondaryAction: CPAlertAction(title: String(localized: "いいえ"), style: .cancel) { _ in },
            duration: 20)
        mapTemplate.present(navigationAlert: alert, animated: true)
    }

    /// 連続運転が長くなったときの催促。
    ///
    /// **`CPNavigationAlert` で出す**（`CPAlertTemplate` ではない）。あちらは画面を
    /// 覆って操作を求めるので、催促のために運転者の手を止めさせることになる。
    /// こちらは案内カードの脇に出て、放っておけば消える。
    /// 読み上げは `VoiceGuidance` が同じ合図で受け持つので、ここでは出さない。
    private func presentRestSuggestion() {
        let alert = CPNavigationAlert(
            titleVariants: [String(localized: "2時間走りました。休憩しませんか")],
            subtitleVariants: nil,
            image: UIImage(systemName: "cup.and.heat.waves.fill"),
            primaryAction: CPAlertAction(title: String(localized: "さがす"), style: .default) { [weak self] _ in
                self?.destinations?.presentRestStops()
            },
            secondaryAction: CPAlertAction(title: String(localized: "あとで"), style: .cancel) { _ in },
            duration: 12)
        mapTemplate.present(navigationAlert: alert, animated: true)
    }

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
        presentAlert(message: String(localized: "目的地を車に送れませんでした"))
    }

    // MARK: 背面のときのバナー

    /// 自アプリが前面でないあいだ、次の指示はバナーとして出る。その距離の更新を
    /// 通してよいかを毎回聞かれるので、**読める文字が変わるときだけ通す**。
    ///
    /// `updateEstimates` は位置更新のたび（毎秒）呼んでいるので、素通しにすると
    /// 1 分に 60 回バナーを描き直させることになる。距離の表記（`Formatters`）が同じなら
    /// 画面は 1 ドットも変わらないので、通す意味が無い。
    ///
    /// **抑えるのは更新だけ。** バナーを出すかどうか（`shouldShowNotificationFor`）は
    /// 実装せず既定に任せている。曲がる指示も助言のアラートも、**前面にいないときこそ
    /// 見せたいもの**で、こちらから止める理由が無い。
    func mapTemplate(_ mapTemplate: CPMapTemplate,
                     shouldUpdateNotificationFor maneuver: CPManeuver,
                     with travelEstimates: CPTravelEstimates) -> Bool {
        let text = Formatters.distanceText(travelEstimates.distanceRemaining.converted(to: .meters).value)
        let maneuverKey = ObjectIdentifier(maneuver)
        // 指示そのものが入れ替わったときは、同じ表記でも通す（別の曲がり角の距離なので）。
        guard notifiedManeuver != maneuverKey || notifiedDistanceText != text else { return false }

        notifiedManeuver = maneuverKey
        notifiedDistanceText = text
        return true
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
        // 「この経路について」が出す対象もここで動かす。動かさないと、候補を切り替えても
        // 先頭の詳細が出続ける（`advisoryNotices` は候補ごとに違うので実害が出る）。
        previewedRoute = route
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
        CarPlayGestureLog.camera("panning began", camera: mapViewController.cameraState())

        // **パン中に残せるマップボタンは 2 つだけ**で、超過ぶんは配列の末尾から
        // CarPlay が勝手に隠す。並び順まかせにすると縮小が落ちるので、ここで
        // 明示的に置き換える。パン中に意味があるのは拡大・縮小だけで、
        // 現在地へ戻すのは「完了」が担い、パンボタン自身はもう用がない。
        mapTemplate.mapButtons = [zoomInButton, zoomOutButton]
        mapTemplate.leadingNavigationBarButtons = []
        mapTemplate.trailingNavigationBarButtons = [donePanningButton]
    }

    func mapTemplateDidDismissPanningInterface(_ mapTemplate: CPMapTemplate) {
        // 押しっぱなしのまま「完了」へ移れる。終了が来ない経路なのでここでも止める。
        stopSustainedPan()
        recenterMap("panning done")
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
        let moved = mapViewController.pan(by: translation, animated: false)
        CarPlayGestureLog.drag(translation: translation, velocity: velocity, moved: moved)
    }

    /// 指が触れた。**追従を切るのはここ**で、最初のデルタを待たない。待つと、
    /// 直前の位置更新で始まった `follow` のアニメーション（0.3 秒ほど）とドラッグの
    /// 頭が殴り合い、動きだしが引っかかってから飛ぶ。触れた時点で切っておけば、
    /// 指を置いたまま動かさないあいだも地図が自車を追って逃げない。
    ///
    /// 惰性で流れている最中に触ったら止める。地図アプリはどれもそう動く。
    func mapTemplateDidBeginPanGesture(_ mapTemplate: CPMapTemplate) {
        stopGlide()
        CarPlayGestureLog.dragBegan()
        mapViewController.setFollowingUser(false)
    }

    /// 指が離れた。最後の速度を惰性へ渡す。
    ///
    /// **中断（着信・Siri・アラートの提示）ではここへ来ない。** CarPlay ホストの
    /// `_handlePanGesture:` は began / changed / ended の 3 つしか分岐しておらず、
    /// `.cancelled` と `.failed` は素通りする（iOS 26.5 の逆アセンブルで確認）。
    /// 惰性を始めそこねるだけで、掴んだままの状態は残らない。
    func mapTemplate(_ mapTemplate: CPMapTemplate, didEndPanGestureWithVelocity velocity: CGPoint) {
        CarPlayGestureLog.dragEnded(velocity: velocity)
        startGlide(velocity: velocity)
    }

    // MARK: 指を離したあとの惰性

    private func startGlide(velocity: CGPoint) {
        stopGlide()
        // ゆっくり置いただけの指で地図を流さない。
        guard hypot(velocity.x, velocity.y) > Self.glideCutoff else { return }
        glideVelocity = velocity
        glideMoved = 0
        // 送りは画面の更新に合わせる。`Timer` だと表示と歩調が合わず、
        // 減速の終わりぎわがかくつく。**止め忘れると `self` を掴んだまま回り続ける**
        // （`CADisplayLink` は target を強く持つ）ので、終わりと `stop()` の両方で切る。
        let link = CADisplayLink(target: self, selector: #selector(stepGlide(_:)))
        link.add(to: .main, forMode: .common)
        glideLink = link
        CarPlayGestureLog.glideBegan(velocity: velocity)
    }

    @objc private func stepGlide(_ link: CADisplayLink) {
        let elapsed = CGFloat(link.targetTimestamp - link.timestamp)
        glideMoved += mapViewController.pan(by: CGPoint(x: glideVelocity.x * elapsed,
                                                        y: glideVelocity.y * elapsed),
                                            animated: false)
        let decay = pow(Self.glideDecay, elapsed * 1_000)
        glideVelocity = CGPoint(x: glideVelocity.x * decay, y: glideVelocity.y * decay)
        if hypot(glideVelocity.x, glideVelocity.y) <= Self.glideCutoff { stopGlide() }
    }

    private func stopGlide() {
        guard let glideLink else { return }
        glideLink.invalidate()
        self.glideLink = nil
        CarPlayGestureLog.glideEnded(moved: glideMoved)
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
    ///
    /// ただし**定数の一致だけには賭けない**。値の意味は逆アセンブルからの推測で、
    /// 実機が 0.9999999 を送ってきたら判定が裏返る。裏返ったタップは `zoom(toScale:)` へ
    /// 流れ、基準が無いので何も起きない — つまり「効かないダブルタップ」になる。
    /// そこで完全一致ではなく幅で見たうえで、**基準を持っていないならピンチの更新では
    /// ありえない**（ピンチは必ず開始から始まる）ことも根拠に足す。
    func mapTemplate(_ mapTemplate: CPMapTemplate,
                     didUpdateZoomGestureWithCenter center: CGPoint,
                     scale: CGFloat,
                     velocity: CGFloat) {
        let matchesTapConstants = abs(scale - 1) < 0.001 && abs(abs(velocity) - 1) < 0.001
        let isTap = matchesTapConstants || !mapViewController.hasZoomBase
        let outcome: GestureOutcome
        if isTap {
            // タップ。拡大・縮小ボタンと同じ 1 段ぶんだけ動かす。
            if velocity > 0 { mapViewController.zoomIn() } else { mapViewController.zoomOut() }
            outcome = .applied
        } else {
            outcome = mapViewController.zoom(toScale: scale)
        }
        CarPlayGestureLog.zoom(center: center, scale: scale, velocity: velocity,
                               isTap: isTap, outcome: outcome, camera: mapViewController.cameraState())
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
        let outcome = mapViewController.rotate(byRadians: rotation)
        CarPlayGestureLog.rotation(center: center, radians: rotation, velocity: velocity,
                                   outcome: outcome, camera: mapViewController.cameraState())
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
        let outcome = mapViewController.pitch(towards: center)
        CarPlayGestureLog.pitch(center: center, outcome: outcome, camera: mapViewController.cameraState())
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, pitchEndedWithCenter center: CGPoint) {
        CarPlayGestureLog.pitchEnded(center: center)
        mapViewController.endPitchGesture()
    }

    // MARK: ノブ・トラックパッドでのパン

    /// パンボタンの callback は**押し方で分かれていて 3 つある**。ヘッダのとおり
    /// `panWithDirection:` は「瞬間的に押した」ぶんだけで、押し続けたときは
    /// `panBeganWithDirection:` →（押しているあいだは無音）→ `panEndedWithDirection:`
    /// に変わる。**揃えないと、ノブしか無い車で押し続けたときに地図が 1px も動かない。**
    /// ドラッグと違ってタッチ精度のゲートが無いぶん、こちらは全部の車で必ず通る。
    ///
    /// 瞬間押しは 1 回あたり画面の約 1/4 だけ動かす。
    func mapTemplate(_ mapTemplate: CPMapTemplate, panWith direction: CPMapTemplate.PanDirection) {
        let moved = mapViewController.pan(by: Self.translation(for: direction, step: 100))
        CarPlayGestureLog.pan(direction: direction, moved: moved)
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, panBeganWith direction: CPMapTemplate.PanDirection) {
        CarPlayGestureLog.panBegan(direction: direction)
        startSustainedPan(towards: direction)
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, panEndedWith direction: CPMapTemplate.PanDirection) {
        stopSustainedPan()
        CarPlayGestureLog.panEnded(direction: direction)
    }

    /// 指に追従させるドラッグと同じく、送っているあいだはアニメーションを掛けない。
    /// 0.1 秒ごとにアニメーションを重ねると、前のぶんが終わる前に次が始まって送りが詰まる。
    private func startSustainedPan(towards direction: CPMapTemplate.PanDirection) {
        stopSustainedPan()
        sustainedPanTimer = Timer.scheduledTimer(withTimeInterval: Self.sustainedPanInterval,
                                                 repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepSustainedPan(towards: direction) }
        }
    }

    private func stepSustainedPan(towards direction: CPMapTemplate.PanDirection) {
        let moved = mapViewController.pan(by: Self.translation(for: direction,
                                                               step: Self.sustainedPanStep),
                                          animated: false)
        CarPlayGestureLog.pan(direction: direction, moved: moved)
    }

    /// **終了が来ないことがある**（パン UI ごと閉じられた場合など）。ジェスチャの
    /// `.cancelled` と同じで、止める側を終了の到着だけに頼らない。
    private func stopSustainedPan() {
        sustainedPanTimer?.invalidate()
        sustainedPanTimer = nil
    }

    private static func translation(for direction: CPMapTemplate.PanDirection, step: CGFloat) -> CGPoint {
        var translation = CGPoint.zero
        if direction.contains(.left) { translation.x += step }
        if direction.contains(.right) { translation.x -= step }
        if direction.contains(.up) { translation.y += step }
        if direction.contains(.down) { translation.y -= step }
        return translation
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
        applyButtons(for: .idle)
    }
}

private extension DrivingSide {
    /// 通行区分そのものは走る国の話なので `Core/` に置き、CarPlay の型への
    /// 読み替えだけをこちら側に持つ。
    var carPlaySide: CPTrafficSide {
        switch self {
        case .left: .left
        case .right: .right
        }
    }
}

private extension TrafficCondition {
    /// 見立てそのものは案内の状態なので `Core/` に置き、色への読み替えだけをこちら側に
    /// 持つ（`DrivingSide.carPlaySide` と同じ分け方）。
    ///
    /// **`.default` に相当する case は作っていない。** 「まだ測っていない」は
    /// `TrafficCondition?` の nil で表しているので、呼ぶ側が `?? .default` で受ける。
    var timeRemainingColor: CPTimeRemainingColor {
        switch self {
        case .flowing: .green
        case .slow: .orange
        case .congested: .red
        }
    }
}

private extension Measurement where UnitType == UnitLength {
    static func meters(_ value: CLLocationDistance) -> Measurement<UnitLength> {
        Measurement(value: value, unit: .meters)
    }
}
