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

    /// リルート計算がいま走っているか。何度も計算を投げないためだけのフラグで、
    /// 公開している `isRerouting` とは寿命が違う（失敗すれば即座に下りて再試行できる）。
    private var isCalculatingReroute = false

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
        phase = .navigating(route)
        location.setNavigating(true)

        // 開始直後に 1 回流し、位置更新を待たずに最初の指示を出す。
        if let current = location.location { handle(location: current) }

        // 下ろすのは最後。CarPlay はこの立ち下がりで `resumeTrip` するので、
        // 新しい経路と最初の進捗が揃う前に下ろすと古い情報で再開してしまう。
        isRerouting = false
    }

    func cancelNavigation() {
        routingTask?.cancel()
        routingTask = nil
        guidance = nil
        announcedStepIndex = nil
        progress = nil
        isCalculatingReroute = false
        isRerouting = false
        phase = .idle
        location.setNavigating(false)
    }

    // MARK: - 位置更新

    private func handle(location current: CLLocation) {
        guard case let .navigating(route) = phase, let guidance else { return }

        let updated = guidance.update(with: current)
        progress = updated

        if updated.hasArrived {
            arrived.send(route)
            cancelNavigation()
            return
        }

        if updated.isOffRoute {
            reroute(to: route.destination, via: remainingWaypoints(of: route))
            return
        }

        if announcedStepIndex != updated.stepIndex {
            let previous = announcedStepIndex
            announcedStepIndex = updated.stepIndex
            notifyWaypointsPassed(on: route, from: previous, to: updated.stepIndex)
            maneuverChanged.send((route: route, stepIndex: updated.stepIndex))
        }
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
    private func reroute(to destination: Place, via waypoints: [Place]) {
        guard !isCalculatingReroute else { return }
        isCalculatingReroute = true
        isRerouting = true

        routingTask?.cancel()
        routingTask = Task {
            defer { isCalculatingReroute = false }
            do {
                let routes = try await calculateRoutes(to: destination, via: waypoints)
                guard !Task.isCancelled, let best = routes.first else { return }
                // 経路に戻せたときだけ `isRerouting` が下りる（startNavigation の末尾）。
                startNavigation(with: best)
            } catch {
                // 引き直しに失敗しても案内は止めない。次の位置更新でまた試す。
                NSLog("[MichiNavi] リルートに失敗: \(error.localizedDescription)")
            }
        }
    }
}

enum NavigationError: LocalizedError {
    case noCurrentLocation

    var errorDescription: String? {
        switch self {
        case .noCurrentLocation: "現在地が取得できていません"
        }
    }
}
