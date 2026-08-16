import Combine
import CoreLocation
import Foundation

/// 航続距離で届かない経路のとき、途中の補給先を提案する。
///
/// **車から来る要求と対になっている。** CarPlay のルート共有では、EV の側が
/// 「このままでは着かないので充電に寄れ」と経由地を送ってくる
/// （`CarPlayCoordinator.mapTemplate(_:didRequestToInsert:into:completion:)`）。
/// ただしそれは対応した車でしか起きないので、こちらからも同じことを言えるようにする。
///
/// 残量ではなく航続距離を使うのは、**車の残量を読む手段がこちらに無い**ため。
/// CarPlay は充電状態を渡してこない。利用者が一度入れた数字で判断する。
@MainActor
final class RangeAdvisor {
    static let shared = RangeAdvisor()

    struct Advice {
        let place: Place
        let kind: RoutePreferences.RefuelKind
    }

    /// 提案が決まった瞬間に流れる。
    let advice = PassthroughSubject<Advice, Never>()

    private let navigation = NavigationController.shared
    private let preferences = RoutePreferences.shared

    /// 航続距離のうち、探索に使ってよい割合。
    ///
    /// 目一杯まで走らせない。カタログの航続距離は実際より伸びるし、補給先が
    /// 目の前にあるとは限らない。手前 8 割で探して余裕を残す。
    private static let usableRatio: Double = 0.8

    /// すでに助言した経路。同じ経路で何度も言わない。
    private var advisedRouteID: UUID?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func start() {
        navigation.$phase
            .sink { [weak self] in self?.apply(phase: $0) }
            .store(in: &cancellables)
    }

    private func apply(phase: NavigationController.Phase) {
        guard case let .navigating(route) = phase else {
            advisedRouteID = nil
            return
        }

        guard advisedRouteID != route.id else { return }
        let range = preferences.vehicleRange
        // 未設定、または届く経路なら黙っている。
        guard range > 0, route.distance > range else { return }

        advisedRouteID = route.id
        Task { await suggest(on: route, range: range) }
    }

    private func suggest(on route: NavRoute, range: CLLocationDistance) async {
        let reachable = NavRoute.coordinates(route.coordinates, upTo: range * Self.usableRatio)
        guard !reachable.isEmpty else { return }

        let kind = preferences.refuelKind
        guard let places = try? await SearchService.shared.alongRoute(
            pointsOfInterest: kind.pointsOfInterest,
            coordinates: reachable) else { return }

        // **いちばん近いものではなく、届く範囲でいちばん先のもの**を選ぶ。
        // 手前で入れると、そのぶん次の補給が早く来る。`alongRoute` は経路の手前から
        // 順に並べて返すので、末尾がいちばん先にある。
        guard let place = places.last else { return }
        advice.send(Advice(place: place, kind: kind))
    }
}
