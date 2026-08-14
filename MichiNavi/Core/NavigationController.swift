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

    /// 案内中に次の指示が変わった瞬間だけ流れる。音声読み上げと
    /// CarPlay の `CPManeuver` 差し替えのトリガーになる。
    let maneuverChanged = PassthroughSubject<(route: NavRoute, stepIndex: Int), Never>()
    /// 目的地に着いた瞬間に流れる。
    let arrived = PassthroughSubject<NavRoute, Never>()

    private let location = LocationService.shared
    private let routeProvider: RouteProviding = MapKitRouteProvider()

    private var guidance: GuidanceEngine?
    private var announcedStepIndex: Int?
    private var routingTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// リルート中に何度も計算を投げないためのフラグ。
    private var isRerouting = false

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

    /// 目的地までのルートを計算して提示状態に入る。
    func requestRoutes(to destination: Place) {
        routingTask?.cancel()
        lastError = nil
        phase = .calculating(destination)

        routingTask = Task {
            do {
                let routes = try await calculateRoutes(to: destination)
                guard !Task.isCancelled else { return }
                phase = .previewing(routes)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                lastError = error.localizedDescription
                phase = .idle
            }
        }
    }

    private func calculateRoutes(to destination: Place) async throws -> [NavRoute] {
        guard let origin = location.location?.coordinate else {
            throw NavigationError.noCurrentLocation
        }
        return try await routeProvider.routes(from: origin, to: destination)
    }

    // MARK: - 案内の開始と終了

    func startNavigation(with route: NavRoute) {
        guidance = GuidanceEngine(route: route)
        announcedStepIndex = nil
        progress = nil
        phase = .navigating(route)
        location.setNavigating(true)

        // 開始直後に 1 回流し、位置更新を待たずに最初の指示を出す。
        if let current = location.location { handle(location: current) }
    }

    func cancelNavigation() {
        routingTask?.cancel()
        routingTask = nil
        guidance = nil
        announcedStepIndex = nil
        progress = nil
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
            reroute(to: route.destination)
            return
        }

        if announcedStepIndex != updated.stepIndex {
            announcedStepIndex = updated.stepIndex
            maneuverChanged.send((route: route, stepIndex: updated.stepIndex))
        }
    }

    /// 経路を外れたときに、いまの位置から同じ目的地へ引き直す。
    private func reroute(to destination: Place) {
        guard !isRerouting else { return }
        isRerouting = true

        routingTask?.cancel()
        routingTask = Task {
            defer { isRerouting = false }
            do {
                let routes = try await calculateRoutes(to: destination)
                guard !Task.isCancelled, let best = routes.first else { return }
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
