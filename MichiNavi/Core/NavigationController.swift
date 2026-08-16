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

    /// 経路を外れて引き直している最中。
    ///
    /// 「いまの状態」なので `@Published`。CarPlay はこれを見て案内カードを
    /// 「再検索中」に差し替える（`pauseTrip` / `resumeTrip`）。
    /// **引き直しに失敗しても下ろさない**。次の位置更新で再試行するあいだ何度も
    /// 上げ下げすると、カードが点滅して逆に何が起きているか分からなくなる。
    @Published private(set) var isRerouting = false

    /// 案内中に次の指示が変わった瞬間だけ流れる。音声読み上げと
    /// CarPlay の `CPManeuver` 差し替えのトリガーになる。
    let maneuverChanged = PassthroughSubject<(route: NavRoute, stepIndex: Int), Never>()
    /// 目的地に着いた瞬間に流れる。
    let arrived = PassthroughSubject<NavRoute, Never>()
    /// 経由地を通過した瞬間に流れる。案内はそのまま続く。
    let waypointReached = PassthroughSubject<Place, Never>()

    private let location = LocationService.shared
    private let routeProvider: RouteProviding = MapKitRouteProvider()

    private var guidance: GuidanceEngine?
    private var announcedStepIndex: Int?
    private var routingTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// 最後に本物の測位を受け取った時刻。途切れの判定に使う。
    private var lastFix: Date?
    /// 測位が途切れているあいだ進捗を進める時計。案内中だけ動く。
    private var deadReckoningTimer: Timer?

    /// リルート計算がいま走っているか。何度も計算を投げないためだけのフラグで、
    /// 公開している `isRerouting` とは寿命が違う（失敗すれば即座に下りて再試行できる）。
    private var isCalculatingReroute = false
    /// 直前の引き直しが終わった時刻。次を投げるまでの間隔をここから測る。
    private var lastRerouteFinished: Date?
    /// 連続で失敗した回数。空ける間隔を決める。成功したら 0 に戻す。
    private var rerouteFailures = 0

    private init() {
        location.$location
            .compactMap { $0 }
            .sink { [weak self] in self?.handle(location: $0) }
            .store(in: &cancellables)
    }

    var currentRoute: NavRoute? {
        if case let .navigating(route) = phase { return route }
        return nil
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
                startNavigation(with: best)
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
        routingTask?.cancel()
        lastError = nil
        // 別の目的地を引き直すので、途中だった再検索の状態は捨てる。
        isRerouting = false
        lastRerouteFinished = nil
        rerouteFailures = 0
        phase = .calculating(destination)

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
                phase = .idle
            }
        }
    }

    private func calculateRoutes(to destination: Place, via waypoints: [Place] = []) async throws -> [NavRoute] {
        guard let origin = location.location?.coordinate else {
            throw NavigationError.noCurrentLocation
        }
        return try await routeProvider.routes(from: origin, via: waypoints, to: destination)
    }

    // MARK: - 案内の開始と終了

    func startNavigation(with route: NavRoute) {
        // 実際に案内を始めた地点だけを履歴に残す。ルートを見ただけでは残さない。
        DestinationStore.shared.remember(route.destination)
        guidance = GuidanceEngine(route: route)
        announcedStepIndex = nil
        progress = nil
        lastFix = nil
        phase = .navigating(route)
        location.setNavigating(true)
        startDeadReckoning()

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

    func cancelNavigation() {
        routingTask?.cancel()
        routingTask = nil
        guidance = nil
        announcedStepIndex = nil
        progress = nil
        lastFix = nil
        deadReckoningTimer?.invalidate()
        deadReckoningTimer = nil
        isCalculatingReroute = false
        isRerouting = false
        lastRerouteFinished = nil
        rerouteFailures = 0
        phase = .idle
        location.setNavigating(false)
    }

    // MARK: - 位置更新

    private func handle(location current: CLLocation) {
        guard case let .navigating(route) = phase, let guidance else { return }

        lastFix = Date()
        let updated = guidance.update(with: current)
        progress = updated

        if updated.hasArrived {
            // 着いた地点を車の置き場所として残す。目的地の座標ではなく**実際に
            // 着いた座標**を使う（施設が目的地なら、車は入口ではなく駐車場にある）。
            DestinationStore.shared.rememberParking(at: current.coordinate, near: route.destination)
            arrived.send(route)
            cancelNavigation()
            return
        }

        if updated.isOffRoute {
            reroute(to: route.destination, via: remainingWaypoints(of: route))
            return
        }

        announceIfNeeded(on: route, stepIndex: updated.stepIndex)
    }

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
        guard case let .navigating(route) = phase, let guidance, let lastFix else { return }

        let elapsed = Date().timeIntervalSince(lastFix)
        guard elapsed >= Self.deadReckoningDelay,
              let updated = guidance.extrapolate(elapsed: elapsed) else { return }

        progress = updated
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
    /// という形で確実に破綻する。
    private func reroute(to destination: Place, via waypoints: [Place]) {
        guard !isCalculatingReroute, canAttemptReroute else { return }
        isCalculatingReroute = true
        isRerouting = true

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
                    return
                }
                rerouteFailures = 0
                // 経路に戻せたときだけ `isRerouting` が下りる（startNavigation の末尾）。
                startNavigation(with: best)
            } catch {
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

enum NavigationError: LocalizedError {
    case noCurrentLocation

    var errorDescription: String? {
        switch self {
        case .noCurrentLocation: "現在地が取得できていません"
        }
    }
}
