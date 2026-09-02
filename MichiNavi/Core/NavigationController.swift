import Combine
import CoreLocation
import MapKit

/// アプリ全体の案内状態を 1 か所に集める。
///
/// iPhone 画面（SwiftUI）と CarPlay 画面（UIKit + CarPlay テンプレート）は
/// どちらもこの `shared` を購読する。どちらで操作しても同じ状態が動く。
@MainActor
final class NavigationController: ObservableObject {
    static let shared = NavigationController()

    enum Phase: Equatable {
        /// 目的地未設定。
        case idle
        /// ルート計算中。
        case calculating(Place)
        /// ルートを提示して開始待ち。
        case previewing([NavRoute])
        /// 案内中。
        case navigating(NavRoute)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): true
            case let (.calculating(l), .calculating(r)): l == r
            case let (.previewing(l), .previewing(r)): l.map(\.id) == r.map(\.id)
            case let (.navigating(l), .navigating(r)): l.id == r.id
            default: false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: RouteProgress?
    @Published private(set) var lastError: String?

    /// **自分では何も出せない入口から、失敗を利用者へ伝えるための口。**
    ///
    /// Dashboard のショートカットがこれを使う。あちらにはテンプレートが出せないので、
    /// 探して見つからなかった・通信が切れていたを黙って落とすと「押しても何も起きない
    /// ボタン」になる。ここへ載せればセンターディスプレイと iPhone がアラートを出すので、
    /// 見に行ったときに理由が残っている。
    ///
    /// **経路計算の失敗はここを通さない**（`requestRoutes` などが自分で載せる）。
    /// これは案内へ入る手前の、探す段で終わってしまったぶんのため。
    func report(error message: String) {
        lastError = message
    }

    /// いま案内している経路。**`phase` とは寿命が違う。**
    ///
    /// 走行中に次の行き先を探すと `phase` は `.calculating` → `.previewing` と動くが、
    /// **車はまだこの経路の上を走っている**。nil になるのは案内が本当に終わったとき
    /// （到着・中止）だけ。
    ///
    /// **「案内が生きているか」を見たい購読側はこちらを見る**（`phase` ではなく）。
    /// `phase` で見ると、走行中にキーボードが使えないぶんいちばんよく通る導線——声と
    /// 「目的地を変更」——を押した瞬間に案内が黙る。逆に**「いまどの画面か」で決まる
    /// ものは `phase` のまま**にしておくこと（CarPlay の案内カードは選んでいるあいだ
    /// 畳んであるので、そこへ指示を送っても行き先が無い）。
    @Published private(set) var activeRoute: NavRoute?

    /// 到着予定がどれだけ遅れているか。CarPlay が到着予定の色に使う。
    ///
    /// **測り直すまでは nil。** 材料が無い状態と「見込みどおり」を混ぜない。混ぜると、
    /// 案内を始めた瞬間から「順調」と言い切ることになる（まだ 1 度も測っていない）。
    @Published private(set) var trafficCondition: TrafficCondition?

    /// 経路を外れて引き直している最中。
    ///
    /// 「いまの状態」なので `@Published`。CarPlay はこれを見て案内カードを
    /// 「再検索中」に差し替える（`pauseTrip` / `resumeTrip`）。
    /// **引き直しに失敗しても下ろさない**。次の位置更新で再試行するあいだ何度も
    /// 上げ下げすると、カードが点滅して逆に何が起きているか分からなくなる。
    /// 例外は停車したとき（[canReroute(from:)]）。再試行そのものを止めるので、
    /// 立てたままにすると検索していないのにカードだけが残る。
    @Published private(set) var isRerouting = false

    /// 直近の経路の入れ替えがなぜ起きたか。**`phase` が `.navigating` になった時点で
    /// もう新しい値**なので、`$phase` を購読している側はそのまま読める
    /// （`@Published` が `willSet` で流れることに乗っている）。
    private(set) var lastRouteChange: RouteChangeReason = .started

    /// 案内中に次の指示が変わった瞬間だけ流れる。音声読み上げと
    /// CarPlay の `CPManeuver` 差し替えのトリガーになる。
    let maneuverChanged = PassthroughSubject<(route: NavRoute, stepIndex: Int), Never>()
    /// 目的地に着いた瞬間に流れる。
    let arrived = PassthroughSubject<NavRoute, Never>()
    /// 経由地を通過した瞬間に流れる。案内はそのまま続く。
    let waypointReached = PassthroughSubject<Place, Never>()

    /// 到着予定を測り直した瞬間に流れる。**測るために引いた経路も一緒に渡す。**
    ///
    /// 測り直しは「いま引き直すとどうなるか」を計算しているので、渋滞の迂回を判断する
    /// 材料がそのまま手に入る。捨てずに流して `TrafficAdvisor` に判断させることで、
    /// **問い合わせを 2 回投げずに済む**（経由地があると区間の数だけ `MKDirections` を
    /// 投げるので、用途ごとに呼ぶと引き直しと同じ重さの問い合わせが倍になる）。
    let travelTimeMeasured = PassthroughSubject<TravelTimeMeasurement, Never>()

    struct TravelTimeMeasurement {
        /// いま案内している経路。
        let route: NavRoute
        /// いま引き直すとこうなる、という経路。
        let candidate: NavRoute
        /// **差し替える前に**見込んでいた残り時間。渋滞かどうかはこの差でしか分からない。
        let projectedTimeRemaining: TimeInterval
        /// 測ったときに走っていた区間。`route` の残りを切り出すのに使う。
        let stepIndex: Int
    }

    /// 圏外で経路を引き直せなかったときに流れる。**圏外が続くあいだは 1 回だけ。**
    ///
    /// 引き直しを見送ると「再検索中」のカードは下りるので、何も出さないと**経路を
    /// 外れたまま無反応**に見える。下ろすことと知らせることは対で要る。
    let rerouteBlockedOffline = PassthroughSubject<Void, Never>()

    private let location = LocationService.shared
    private let network = NetworkMonitor.shared
    private let routeProvider: RouteProviding = MapKitRouteProvider()

    private var guidance: GuidanceEngine?
    private var announcedStepIndex: Int?
    private var routingTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// 最後に本物の測位を受け取った時刻。途切れの判定に使う。
    private var lastFix: Date?
    /// 測位が途切れているあいだ進捗を進める時計。案内中だけ動く。
    private var deadReckoningTimer: Timer?
    /// いまの途切れについて「推測でも進めない」を記録したか。実測が 1 回来たら倒す。
    private var hasReportedDeadReckoningStall = false

    /// リルート計算がいま走っているか。何度も計算を投げないためだけのフラグで、
    /// 公開している `isRerouting` とは寿命が違う（失敗すれば即座に下りて再試行できる）。
    private var isCalculatingReroute = false
    /// 直前の引き直しが終わった時刻。次を投げるまでの間隔をここから測る。
    private var lastRerouteFinished: Date?
    /// 連続で失敗した回数。空ける間隔を決める。成功したら 0 に戻す。
    private var rerouteFailures = 0
    /// 直前に引き直した地点。次を投げるまでに動くべき距離をここから測る。
    private var lastRerouteOrigin: CLLocation?
    /// いまの圏外について、もう知らせたか。電波が戻ったら倒す。
    private var hasReportedOffline = false

    /// 到着予定を最後に測り直した時刻。
    private var lastTravelTimeRefresh: Date?
    private var isRefreshingTravelTime = false

    private init() {
        location.$location
            .compactMap { $0 }
            .sink { [weak self] in self?.handle(location: $0) }
            .store(in: &cancellables)

        network.$isOnline
            .removeDuplicates()
            .sink { [weak self] in self?.apply(isOnline: $0) }
            .store(in: &cancellables)
    }

    /// 電波が戻ったら、圏外のあいだに溜めた我慢を捨てる。
    ///
    /// 失敗を数えているのは**道が見つからないとき**に MapKit を叩き続けないためで、
    /// 圏外で失敗したぶんは性質が違う。そのまま数えたままにすると、電波が戻っても
    /// 最大 40 秒（`rerouteInterval` の頭打ち）待たされる。トンネルを出た直後は
    /// いちばん引き直してほしい場面なので、そこで待たせない。
    private func apply(isOnline: Bool) {
        guard isOnline else { return }
        rerouteFailures = 0
        lastRerouteFinished = nil
        hasReportedOffline = false
    }

    /// **いま案内の段階にある**経路。案内カードのように「その画面が出ているあいだだけ
    /// 意味を持つ」ものはこちらを見る。走っている経路そのものは [activeRoute]。
    var currentRoute: NavRoute? {
        if case let .navigating(route) = phase { return route }
        return nil
    }

    /// いま案内の段階にいるか。**「案内が生きているか」とは別**（あちらは [activeRoute]）。
    /// 次の行き先を選んでいるあいだは、案内が生きたままこちらだけ false になる。
    private var isNavigatingPhase: Bool {
        if case .navigating = phase { return true }
        return false
    }

    var previewedRoutes: [NavRoute] {
        if case let .previewing(routes) = phase { return routes }
        return []
    }

    // MARK: - 目的地の設定

    /// 目的地までのルートを計算して提示状態に入る。開始するかは利用者が選ぶ。
    func requestRoutes(to destination: Place) {
        route(to: destination) { [weak self] routes in
            self?.phase = .previewing(routes)
        }
    }

    /// ルートを計算してそのまま案内を始める。
    /// CarPlay Dashboard のショートカットのように、提示画面を見てもらえない
    /// 場所から呼ばれる想定。
    func startNavigation(to destination: Place) {
        route(to: destination) { [weak self] routes in
            guard let best = routes.first else { return }
            self?.startNavigation(with: best)
        }
    }

    /// 案内中の経路に立ち寄り先を挟む。いまの位置から引き直して、そのまま案内を続ける。
    ///
    /// 追加する先は**いちばん後ろ**（目的地の直前）。位置関係から順番を組み替えるには
    /// 巡回セールスマン問題を解くことになり、MapKit にその機能は無い。
    /// 案内していないときは、ただの目的地として扱う。
    func addWaypoint(_ place: Place) {
        guard case let .navigating(route) = phase else {
            requestRoutes(to: place)
            return
        }

        let waypoints = remainingWaypoints(of: route) + [place]
        routingTask?.cancel()
        routingTask = Task {
            do {
                let routes = try await calculateRoutes(to: route.destination, via: waypoints)
                guard !Task.isCancelled, let best = routes.first else { return }
                startNavigation(with: best, reason: .waypointAdded)
            } catch is CancellationError {
                return
            } catch {
                // 引き直しに失敗しても、いまの案内は続いている。知らせるだけにする。
                lastError = error.localizedDescription
            }
        }
    }

    /// 立ち寄り先を挟んだ場合の距離と所要を、**いまの案内を変えずに**試算する。
    ///
    /// 車から「充電に寄れ」と提案が来たとき、受けるかどうかを決める材料として
    /// CarPlay に渡す数字。まだ受けると決まっていないので、`routingTask` は取り消さない
    /// （取り消すと、走っている引き直しを試算が横から潰す）。
    func estimate(inserting place: Place) async -> (distance: CLLocationDistance, travelTime: TimeInterval)? {
        guard case let .navigating(route) = phase else { return nil }

        let waypoints = remainingWaypoints(of: route) + [place]
        guard let best = try? await calculateRoutes(to: route.destination, via: waypoints).first else {
            return nil
        }
        return (best.distance, best.expectedTravelTime)
    }

    /// その時刻に着くには何時に出ればよいか。
    ///
    /// 予定のある移動では、検索より使う数字になる。所要時間は到着時刻によって変わる
    /// （朝の 9 時着と深夜 2 時着では混み具合が違う）ので、単純に「いまの所要時間」を
    /// 引き算しても答えにならない。
    func departureTime(toArriveBy date: Date, at destination: Place) async -> Date? {
        guard let origin = location.location?.coordinate else { return nil }
        guard let travelTime = try? await routeProvider.travelTime(from: origin,
                                                                   to: destination,
                                                                   arrivingBy: date) else { return nil }
        return date.addingTimeInterval(-travelTime)
    }

    /// まだ通っていない経由地。引き直すときに引き継ぐ。
    private func remainingWaypoints(of route: NavRoute) -> [Place] {
        let stepIndex = progress?.stepIndex ?? 0
        return zip(route.waypoints, route.waypointStepIndices)
            .filter { stepIndex <= $0.1 }
            .map(\.0)
    }

    private func route(to destination: Place,
                       via waypoints: [Place] = [],
                       then handle: @escaping ([NavRoute]) -> Void) {
        // **圏外なら段階を動かさない。** 計算中にしてから MapKit の一般的なエラーで
        // 落とすより、押した時点で理由を返すほうが早いし、何が悪いのかも分かる。
        guard network.isOnline else {
            lastError = NavigationError.offline.errorDescription
            return
        }
        routingTask?.cancel()
        lastError = nil
        phase = .calculating(destination)
        // 別の目的地を引き直すので、途中だった再検索の状態は捨てる。
        //
        // **下ろすのは `phase` を動かしたあと。** 立ち下がりを購読している CarPlay は
        // `resumeTrip` を投げるので、まだ `.navigating` のうちに下ろすと、**いま捨てようと
        // している経路**を「引き直しの結果」として車へ渡してしまう。`.calculating` を
        // 先に流しておけば、あちらはセッションを畳んでから受け取るので何も起きない。
        isRerouting = false
        lastRerouteFinished = nil
        rerouteFailures = 0
        lastRerouteOrigin = nil

        routingTask = Task {
            do {
                let routes = try await calculateRoutes(to: destination, via: waypoints)
                guard !Task.isCancelled else { return }
                handle(routes)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                lastError = error.localizedDescription
                // **`phase` を直に `.idle` にしない。** 案内中に別の目的地を選んで計算が
                // 失敗すると、CarPlay は `.idle` を見てセッションを畳むのに、こちらは
                // 案内中の持ち物を抱えたまま残る。`deadReckoningTimer` を止めるのも
                // `location.setNavigating(false)` を呼ぶのも `cancelNavigation()` だけなので、
                // 1 秒ごとの時計が空回りし続け、待機中の地図を出しながら背景測位の
                // インジケータが出たままになる。
                cancelNavigation()
            }
        }
    }

    private func calculateRoutes(to destination: Place, via waypoints: [Place] = []) async throws -> [NavRoute] {
        guard let origin = location.location?.coordinate else {
            throw NavigationError.noCurrentLocation
        }
        var routes = try await routeProvider.routes(from: origin, via: waypoints, to: destination)
        let percentages = RouteNovelty.percentages(for: routes, tracks: TrackStore.shared.tracks)
        let characters = RouteCharacter.tags(for: routes)
        let departure = Date()
        for index in routes.indices {
            routes[index].newRoadPercentage = percentages[index]
            routes[index].driveBrief = DriveBrief.make(for: routes[index],
                                                       comparisonTags: characters[index],
                                                       departure: departure)
        }
        return routes
    }

    // MARK: - 案内の開始と終了

    /// 計算済みの経路で案内を始める（差し替えも同じ道を通る）。
    ///
    /// `reason` は**読み上げの最初のひと言にしか効かない**。経路の差し替え方は理由に
    /// よらず同じ。既定を `.started` にしてあるのは、外から呼ぶ入口（提示画面の開始
    /// ボタン）がそれだから。
    func startNavigation(with route: NavRoute, reason: RouteChangeReason = .started) {
        // **`phase` を動かす前に置く。** `@Published` は `willSet` で流れるので、
        // 購読側（`VoiceGuidance`）が `.navigating` を受け取った時点でここは
        // もう新しい値でなければならない。
        lastRouteChange = reason
        // 実際に案内を始めた地点だけを履歴に残す。ルートを見ただけでは残さない。
        DestinationStore.shared.remember(route.destination)
        guidance = GuidanceEngine(route: route)
        // **`phase` より先に置く。** 案内が生きているかを見ている側（`VoiceGuidance`）は
        // こちらを購読しているので、経路と読み上げの段取りをここで揃える。
        activeRoute = route
        announcedStepIndex = nil
        progress = nil
        lastFix = nil
        phase = .navigating(route)
        location.setNavigating(true)
        startDeadReckoning()
        // 引いたばかりの経路には出発時の見積もりが入っているので、すぐには測り直さない。
        lastTravelTimeRefresh = Date()
        // **見立ても一緒に捨てる。** 比べる相手（`route.expectedTravelTime`）が
        // 入れ替わったので、前の経路で見た遅れをそのまま持ち越すと根拠を失った色が残る。
        trafficCondition = nil
        NavigationLog.navigationStarted(steps: route.steps.count, distance: route.distance)

        // 開始直後に 1 回流し、位置更新を待たずに最初の指示を出す。
        if let current = location.location { handle(location: current) }

        // 下ろすのは最後。CarPlay はこの立ち下がりで `resumeTrip` するので、
        // 新しい経路と最初の進捗が揃う前に下ろすと古い情報で再開してしまう。
        isRerouting = false
    }

    /// 測位が途切れているあいだの推測を回す時計。
    /// 案内が終わったら必ず止める。止めないと `guidance` を掴んだまま回り続ける。
    private func startDeadReckoning() {
        deadReckoningTimer?.invalidate()
        deadReckoningTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceWhileWaitingForFix() }
        }
    }

    /// 走っている案内を終わらせる。**段階は動かさない。**
    ///
    /// `cancelNavigation()` から分けてあるのは、**次の行き先を選んでいるあいだに元の
    /// 目的地へ着くことがある**ため。そこで `.idle` まで落とすと、利用者が見ている候補が
    /// 消える。いっぽう trip の後始末（駐車位置を残す・時計を止める・背景測位を降りる）は
    /// どちらの道でも要る。
    ///
    /// **`routingTask` は取り消さない。** 選んでいる最中に着いたのなら、それは利用者が
    /// 待っている目的地の計算そのもの。取り消すのは `.idle` へ落とすときだけ。
    private func finishTrip() {
        guidance = nil
        // 案内が本当に終わるのはここだけ。読み上げもこの立ち下がりで止まる。
        activeRoute = nil
        announcedStepIndex = nil
        progress = nil
        lastFix = nil
        hasReportedDeadReckoningStall = false
        deadReckoningTimer?.invalidate()
        deadReckoningTimer = nil
        isCalculatingReroute = false
        lastRerouteFinished = nil
        rerouteFailures = 0
        lastRerouteOrigin = nil
        isRefreshingTravelTime = false
        lastTravelTimeRefresh = nil
        trafficCondition = nil
        hasReportedOffline = false
        location.setNavigating(false)
    }

    func cancelNavigation() {
        routingTask?.cancel()
        routingTask = nil
        finishTrip()
        phase = .idle
        // **下ろすのは `phase` を動かしたあと**（`route(to:)` と同じ理由）。まだ
        // `.navigating` のうちに下ろすと、立ち下がりを見ている CarPlay が畳む寸前の
        // セッションへ `resumeTrip` を投げる。そのとき `progress` はもう nil なので、
        // MapKit が出発地に置く 0m・指示文の空の step から案内を渡し直すことになる。
        isRerouting = false
    }

    // MARK: - 位置更新

    /// **案内が生きているかは `activeRoute` で見る。`phase` ではない。**
    ///
    /// 走行中に次の行き先を探すと `phase` は `.calculating` → `.previewing` と動くが、
    /// 車はまだ元の経路の上を走っている。`phase` で判定すると、押した瞬間から `progress`
    /// が流れなくなり、**決めるまで案内が黙る**。走行中はキーボードが塞がれるので、
    /// 声と「目的地を変更」がその状態に入る唯一の道で、いちばんよく通る道でもある。
    ///
    /// そのうえで、**画面が出ているあいだだけ意味を持つものは `phase` で切る**
    /// （下の 2 か所）。
    private func handle(location current: CLLocation) {
        guard let guidance, let route = activeRoute else { return }

        lastFix = Date()
        hasReportedDeadReckoningStall = false
        let updated = guidance.update(with: current)
        progress = updated

        if updated.hasArrived {
            // **到着を残す。** 出ていなければ「まだ着いたと思っていない」と分かる。
            // 画面には「案内が終わらない」という形でしか出ないので、これが無いと
            // 判定が成立しなかったのか、成立したのに後始末が動かなかったのかを
            // 切り分けられない。
            NavigationLog.arrived(remaining: updated.distanceRemaining)
            // 着いた地点を車の置き場所として残す。目的地の座標ではなく**実際に
            // 着いた座標**を使う（施設が目的地なら、車は入口ではなく駐車場にある）。
            DestinationStore.shared.rememberParking(at: current.coordinate, near: route.destination)
            arrived.send(route)
            // **段階を落とすのは案内の段階にいるときだけ。** 次の行き先を選んでいる最中に
            // 元の目的地へ着くことはありうるが、そこで `.idle` へ落とすと**利用者が見ている
            // 候補が消える**（`cancelNavigation()` は待っている経路計算も取り消す）。
            // 着いたこと自体は同じに扱う——駐車位置は残るし、読み上げも走る。
            if isNavigatingPhase {
                cancelNavigation()
            } else {
                finishTrip()
            }
            return
        }

        if updated.isOffRoute {
            NavigationLog.offRoute(distanceFromRoute: updated.distanceFromRoute,
                                   accuracy: current.horizontalAccuracy,
                                   speed: current.speed)
            reroute(to: route.destination, via: remainingWaypoints(of: route), from: current)
            return
        }

        // **ここから下は案内の段階でだけ。** 指示の差し替えは CarPlay の案内カード
        // （選んでいるあいだは畳んである）を宛先にしており、到着予定の測り直しは結果を
        // `.navigating` でしか受け取らない（`MKDirections` を投げるだけ無駄になる）。
        guard isNavigatingPhase else { return }
        announceIfNeeded(on: route, stepIndex: updated.stepIndex)
        refreshTravelTimeIfNeeded(on: route)
    }

    // MARK: - 到着予定の測り直し

    /// 残り時間を交通状況で測り直す。
    ///
    /// `GuidanceEngine` の残り時間は残距離への比例でしか出せない（MKRoute が step ごとの
    /// 所要時間を返さない）。基準を出発時の見積もりのままにすると、**渋滞に入っても
    /// 数字が動かない**。運転者がいちばん見る数字なので、時々測り直して基準を置き直す。
    ///
    /// **経路そのものは差し替えない。** 走行中に経路が入れ替わると音声も案内カードも
    /// 追随できないというのは、`RoutePreferences` を変えても引き直さないのと同じ判断。
    /// 動かすのは数字だけ。
    private func refreshTravelTimeIfNeeded(on route: NavRoute) {
        // 引き直している最中は測らない。どのみち経路が入れ替われば基準ごと作り直しになる。
        // 圏外なら投げない。引き直しと同じで、失敗するだけの問い合わせになる。
        guard network.isOnline, !isRefreshingTravelTime, !isRerouting else { return }
        if let lastTravelTimeRefresh,
           Date().timeIntervalSince(lastTravelTimeRefresh) < Self.travelTimeRefreshInterval { return }
        guard let origin = location.location?.coordinate else { return }

        isRefreshingTravelTime = true
        Task {
            defer {
                isRefreshingTravelTime = false
                lastTravelTimeRefresh = Date()
            }

            guard let candidate = try? await routeProvider.currentBestRoute(
                from: origin,
                via: remainingWaypoints(of: route),
                to: route.destination) else { return }
            // 待っているあいだに引き直しが挟まっていたら、測った値は前の経路のもの。捨てる。
            guard case let .navigating(current) = phase, current.id == route.id else { return }

            // **差し替える前に控える。** `applyMeasuredTimeRemaining` を通したあとの
            // 見込みは測った値そのものになるので、渋滞かどうかを見る差が消える。
            let projected = progress?.timeRemaining
            let stepIndex = progress?.stepIndex
            updateTrafficCondition(measured: candidate.expectedTravelTime, on: route)
            guidance?.applyMeasuredTimeRemaining(candidate.expectedTravelTime)

            guard let projected, let stepIndex else { return }
            travelTimeMeasured.send(TravelTimeMeasurement(route: current,
                                                          candidate: candidate,
                                                          projectedTimeRemaining: projected,
                                                          stepIndex: stepIndex))
        }
    }

    /// 測った残り時間を、経路を引いたときの見込みと比べて見立てを置き直す。
    ///
    /// **比べる相手は `progress.timeRemaining` ではない。** あちらは前回の測り直しを
    /// 起点にした按分なので、測るたびに自分自身と比べることになって差が出ない。
    /// 経路が持っている出発時（引き直し時）の見積もりを残距離で按分し直したものと比べる。
    ///
    /// 測った値は**いま引き直した場合の**所要時間なので、こちらが走っている道より
    /// 早い道が見つかればその時間になる。数字だけを差し替える
    /// （`applyMeasuredTimeRemaining`）のと同じ値なので、**運転者が見ている到着予定と
    /// 色の根拠は必ず一致する**。走る道が本当に早いかどうかは `TrafficAdvisor` の話。
    private func updateTrafficCondition(measured: TimeInterval, on route: NavRoute) {
        guard let remaining = progress?.distanceRemaining, route.distance > 0 else { return }
        trafficCondition = TrafficCondition(
            measured: measured,
            expected: route.expectedTravelTime * (remaining / route.distance))
    }

    /// 測り直す間隔。
    ///
    /// **短くしないこと**。経由地があると区間の数だけ `MKDirections` を投げるので、
    /// ここを詰めると引き直しと同じ重さの問い合わせを走り続けることになる
    /// （`SearchService.alongRoute` の検索点を増やすなという話と同じ枠）。
    /// 混み具合は分単位でしか変わらないので、これで足りる。
    private static let travelTimeRefreshInterval: TimeInterval = 180

    private func announceIfNeeded(on route: NavRoute, stepIndex: Int) {
        guard announcedStepIndex != stepIndex else { return }
        let previous = announcedStepIndex
        announcedStepIndex = stepIndex
        notifyWaypointsPassed(on: route, from: previous, to: stepIndex)
        maneuverChanged.send((route: route, stepIndex: stepIndex))
    }

    // MARK: - 測位が途切れているあいだ

    /// 測位が来なくなってからこれだけ経ったら、推測で進める。
    /// 1 秒ごとに来る更新が 2 回続けて落ちた、という程度の間合い。
    private static let deadReckoningDelay: TimeInterval = 3

    /// トンネルなどで測位が途切れているあいだ、最後の速度で経路上を進める。
    ///
    /// **リルートも到着もここからは起こさない**（`GuidanceEngine.extrapolate` が
    /// どちらも判定しない）。動かしているのは表示と、次の指示を出す時刻だけ。
    private func advanceWhileWaitingForFix() {
        guard let guidance, let route = activeRoute, let lastFix else { return }

        let elapsed = Date().timeIntervalSince(lastFix)
        guard elapsed >= Self.deadReckoningDelay else { return }
        guard let updated = guidance.extrapolate(elapsed: elapsed) else {
            // **推測でも進めなくなった。ここから先は測位が戻るまで到着しない**
            // （推測では到着を判定しないので）。画面は最後に測れた値で止まるだけなので、
            // これを残さないと「案内が凍った」以上のことが後から分からない。
            // 1 回の途切れにつき 1 行だけ出す（毎秒来るので素通しにすると埋まる）。
            if !hasReportedDeadReckoningStall {
                hasReportedDeadReckoningStall = true
                NavigationLog.deadReckoningStalled(elapsed: elapsed,
                                                   remaining: progress?.distanceRemaining)
            }
            return
        }

        progress = updated
        // `handle(location:)` と同じ切り分け。表示と読み上げは進めるが、案内カードへの
        // 差し替えは画面が出ているあいだだけ。
        guard isNavigatingPhase else { return }
        announceIfNeeded(on: route, stepIndex: updated.stepIndex)
    }

    /// 区間が進んだ間にあった経由地を、通過したものとして知らせる。
    /// GPS が飛んで一度に複数の区間を跨いでも取りこぼさないよう、範囲で見る。
    private func notifyWaypointsPassed(on route: NavRoute, from previous: Int?, to current: Int) {
        guard let previous else { return }

        for (place, index) in zip(route.waypoints, route.waypointStepIndices)
        where index >= previous && index < current {
            waypointReached.send(place)
        }
    }

    /// 経路を外れたときに、いまの位置から同じ目的地へ引き直す。
    /// まだ通っていない経由地は引き継ぐ。落とすと、外れた拍子に立ち寄り先が消える。
    ///
    /// **必ず間隔を空けること**。`GuidanceEngine` の逸脱判定は一度成立すると経路に戻るまで
    /// 下りないので、`handle` は位置更新のたび（およそ毎秒）ここへ来る。計算中かどうかだけで
    /// 抑えると、1 回終わるそばから次を投げることになり、
    ///
    ///   - 失敗したとき: MapKit に絞られてまた失敗する、の繰り返しになる
    ///   - 成功したとき: 数秒ごとにルートが入れ替わり、音声が「再検索しました」を言い続け、
    ///     CarPlay の「再検索中」カードが点滅する
    ///
    /// という形で確実に破綻する。**間隔だけでは足りない**ので、停まっているあいだは
    /// そもそも投げない（[canReroute(from:)]）。
    private func reroute(to destination: Place, via waypoints: [Place], from current: CLLocation) {
        // **次の行き先を選んでいるあいだは引き直さない。** `routingTask` は 1 本しかないので、
        // ここで投げると**利用者が待っている目的地の計算を取り消す**。しかも成功すれば
        // `startNavigation(with:)` が `phase` を `.navigating` へ戻すので、**候補の一覧が
        // 消えて元の経路の案内に引き戻される**。走り出す道が変わらない停車中と同じで、
        // 決まるまで待って損はない。
        //
        // `isRerouting` はここでは触らない。`route(to:)` がもう下ろしているうえ、
        // 案内から出た時点で CarPlay のセッションごと畳んであるので、
        // 「検索していないのに再検索中のカードが残る」形にならない。
        guard isNavigatingPhase else {
            NavigationLog.rerouteSkipped("choosing")
            return
        }
        // **圏外なら投げない。** MapKit の経路計算はネットワーク越しなので必ず失敗する。
        // 投げれば失敗が数えられて間隔が伸び、電波が戻ってからも待たされる。
        // 停車のときと同じく、**何も検索していないのだから「再検索中」は下ろす**。
        guard network.isOnline else {
            if !isCalculatingReroute { isRerouting = false }
            NavigationLog.rerouteSkipped("offline")
            // 下ろしただけだと、経路を外れたまま何も出ない画面になる。1 回だけ知らせる。
            if !hasReportedOffline {
                hasReportedOffline = true
                rerouteBlockedOffline.send()
            }
            return
        }
        guard canReroute(from: current) else {
            // 停まっているあいだは**何も検索していない**ので「再検索中」を出したままにしない。
            // 失敗しても下ろさない作りなので、ここで下ろさないと、動き出して引き直しが
            // 成功するまで赤いカードが出っぱなしになる（停めたまま案内を切れば永久に）。
            // 計算が走っている最中だけは触らない。終わらせ方はそちらに任せる。
            if !isCalculatingReroute { isRerouting = false }
            NavigationLog.rerouteSkipped("stopped")
            return
        }
        guard !isCalculatingReroute else {
            NavigationLog.rerouteSkipped("calculating")
            return
        }
        guard canAttemptReroute else {
            NavigationLog.rerouteSkipped("interval")
            return
        }
        isCalculatingReroute = true
        isRerouting = true
        lastRerouteOrigin = current
        NavigationLog.rerouteStarted()

        let previous = currentRoute?.signature

        routingTask?.cancel()
        routingTask = Task {
            // 次に試してよい時刻は、始めたときではなく**終わったとき**から測る。
            // 経由地つきは区間の数だけ計算するので、始点から測ると終わった瞬間に次が走る。
            defer {
                isCalculatingReroute = false
                lastRerouteFinished = Date()
            }

            do {
                let routes = try await calculateRoutes(to: destination, via: waypoints)
                guard !Task.isCancelled else { return }

                guard let best = routes.first else {
                    rerouteFailures += 1
                    NavigationLog.rerouteFinished(succeeded: false, changed: false)
                    return
                }
                rerouteFailures = 0
                NavigationLog.rerouteFinished(succeeded: true, changed: best.signature != previous)
                // 経路に戻せたときだけ `isRerouting` が下りる（startNavigation の末尾）。
                startNavigation(with: best, reason: .rerouted)
            } catch {
                NavigationLog.rerouteFinished(succeeded: false, changed: false)
                // 引き直しに失敗しても案内は止めない。間隔を空けてまた試す。
                rerouteFailures += 1
                NSLog("[MichiNavi] リルートに失敗: \(error.localizedDescription)")
            }
        }
    }

    /// 次の引き直しを試してよいか。
    private var canAttemptReroute: Bool {
        guard let lastRerouteFinished else { return true }
        return Date().timeIntervalSince(lastRerouteFinished) >= rerouteInterval
    }

    /// **停まっているあいだは引き直さない。**
    ///
    /// 停まっている車に新しい経路を渡しても、走り出す道は変わらない。得るものが無い一方、
    /// 引き直しは必ず「ルートを再検索しました」の読み上げと「再検索中」のカードを連れてくる。
    ///
    /// 実害はここから始まる。逸脱判定は経路に戻るまで下りないので、外れた場所に停めると
    /// [minimumRerouteInterval] ごとに引き直しが走り続ける。しかも停まっている＝入力が
    /// 同じなので、MapKit は毎回**まったく同じ経路**を返す。中心線から 50m 前後
    /// （＝`GuidanceEngine.offRouteThreshold` の境目）に停めた場合はもっと悪く、測位の
    /// 揺れで逸脱の成立と解除を往復するため、引き直しは何度でも成立する。
    /// 一般のカーナビが停車中に引き直さないのはこれを避けるため。
    ///
    /// 判定は 2 段。速度が取れるならそれで見て、取れない端末や、停車中に速度だけ
    /// 跳ねた測位のために、前回引いた地点からの移動距離でも受ける。
    private func canReroute(from current: CLLocation) -> Bool {
        // `speed` は取れないとき負を返す。取れているときだけ停車の判定に使う。
        if current.speed >= 0, current.speed < Self.stoppedSpeed { return false }

        // **1 回目は通す**（`lastRerouteOrigin` が nil）。わざと別の道へ入ったときの
        // 反応を鈍らせない。効かせるのは 2 回目以降だけで、時間の間隔と同じ考え方。
        guard let lastRerouteOrigin else { return true }
        return current.distance(from: lastRerouteOrigin) >= Self.minimumRerouteDistance
    }

    /// これを下回ったら停まっているとみなす速度（m/s）。徒歩よりはっきり遅くしてある。
    /// 渋滞の徐行で引き直しを止めてしまわないため。
    private static let stoppedSpeed: CLLocationSpeed = 1

    /// 2 回目以降の引き直しに必要な移動距離。測位の揺れでは届かず、走っていれば
    /// 数秒で越える値。
    private static let minimumRerouteDistance: CLLocationDistance = 50

    /// 次に試すまでの間隔。連続で失敗するほど空けて、MapKit を叩き続けない。
    /// 5 / 10 / 20 / 40 秒で頭打ちにする。
    private var rerouteInterval: TimeInterval {
        Self.minimumRerouteInterval * pow(2, Double(min(rerouteFailures, 3)))
    }

    /// 引き直しを試す最短間隔。**外れた直後の 1 回目は待たない**
    /// （`lastRerouteFinished` が nil なので即座に走る）。ここで効かせるのは 2 回目以降で、
    /// わざと別の道へ入ったときの反応を鈍らせずに、連打だけを止める。
    private static let minimumRerouteInterval: TimeInterval = 5
}

/// 経路が入れ替わった理由。
///
/// **読み上げの最初のひと言がこれで変わる**ので、入れ替える側が必ず添える。
/// 経路そのものは同じように差し替わるが、利用者から見ると「勝手に引き直された」のと
/// 「自分で押して切り替えた」のはまったく別の出来事で、同じ文言で言われると
/// 押したことが効いたのかどうかが分からない。
///
/// **`Phase` に持たせていない。** あちらは「いまどの段階か」で、こちらは「どうして
/// そうなったか」。段階の比較（`Phase ==`）に理由が混ざると、同じ経路の出し直しが
/// 別物として扱われる。
enum RouteChangeReason {
    /// 目的地を決めて案内を始めた。
    case started
    /// 経路を外れたので引き直した。
    case rerouted
    /// 立ち寄り先を挟んだ。
    case waypointAdded
    /// 利用者が選んで別の道へ切り替えた（渋滞の迂回）。
    case switched
}

enum NavigationError: LocalizedError {
    case noCurrentLocation
    case offline

    var errorDescription: String? {
        switch self {
        case .noCurrentLocation: String(localized: "現在地が取得できていません")
        case .offline: String(localized: "圏外です。電波の届く場所で試してください")
        }
    }
}
