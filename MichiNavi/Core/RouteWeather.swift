import Combine
import CoreLocation
import Foundation
import WeatherKit

/// 経路の先の天気を見て、走り方が変わるものだけ知らせる。
///
/// WeatherKit は Apple 純正なので、**外部パッケージを足さないという前提を守れる**
/// 唯一の天気の入手先。ただし `com.apple.developer.weatherkit` のケイパビリティが要る
/// （CarPlay の entitlement と同じで、App ID 側の有効化も別途必要）。
/// **有効化されるまでは問い合わせが失敗し、この機能は黙って何もしない。**
///
/// 出すのは 3 つだけ。気温・降水・降雪を全部並べても運転は変わらないので、
/// 「知っていたら支度や速度が変わるもの」に絞る。
@MainActor
final class RouteWeather {
    static let shared = RouteWeather()

    enum Hazard: Equatable {
        case rain
        case snow
        /// 路面凍結の恐れ。
        case freezing

        var message: String {
            switch self {
            case .rain: "この先は雨の予報です"
            case .snow: "この先は雪の予報です"
            case .freezing: "この先は気温が低く、路面が凍結する恐れがあります"
            }
        }

        var symbolName: String {
            switch self {
            case .rain: "cloud.rain.fill"
            case .snow: "cloud.snow.fill"
            case .freezing: "thermometer.snowflake"
            }
        }
    }

    /// 注意が決まった瞬間に流れる。
    let hazard = PassthroughSubject<Hazard, Never>()

    private let navigation = NavigationController.shared

    /// 凍結を疑い始める気温（摂氏）。0℃ ちょうどではなく手前から言うのは、
    /// 気温が路面温度より高く出るため。橋の上は先に凍る。
    private static let freezingThreshold: Double = 3
    /// 経路上に置く問い合わせ点の数。**増やさないこと**。WeatherKit には
    /// 呼び出し数の上限があり、経路 1 本ごとにこの数だけ叩く。
    private static let sampleCount = 3

    private var checkedRouteID: UUID?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func start() {
        navigation.$phase
            .sink { [weak self] in self?.apply(phase: $0) }
            .store(in: &cancellables)
    }

    private func apply(phase: NavigationController.Phase) {
        guard case let .navigating(route) = phase else {
            checkedRouteID = nil
            return
        }
        guard checkedRouteID != route.id else { return }
        checkedRouteID = route.id
        Task { await check(route) }
    }

    private func check(_ route: NavRoute) async {
        let service = WeatherService.shared

        for coordinate in Self.samples(of: route) {
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            guard let weather = try? await service.weather(for: location) else {
                // ケイパビリティが無い・圏外・上限に達した、のどれでも同じ扱い。
                // 天気が分からないことで案内を止める理由は無い。
                return
            }

            let current = weather.currentWeather
            if let found = Self.hazard(condition: current.condition,
                                       temperature: current.temperature.converted(to: .celsius).value) {
                // **最初に見つかった 1 件だけ**。手前から順に見ているので、
                // いちばん早く出会う注意が出る。全部並べても運転は変わらない。
                hazard.send(found)
                return
            }
        }
    }

    private static func hazard(condition: WeatherCondition, temperature: Double) -> Hazard? {
        if temperature <= freezingThreshold { return .freezing }

        switch condition {
        case .blizzard, .blowingSnow, .flurries, .heavySnow, .snow, .sunFlurries, .wintryMix:
            return .snow
        case .drizzle, .freezingDrizzle, .freezingRain, .heavyRain, .rain, .sunShowers,
             .hail, .hurricane, .isolatedThunderstorms, .thunderstorms, .tropicalStorm,
             .scatteredThunderstorms, .strongStorms:
            return .rain
        default:
            return nil
        }
    }

    /// 経路上に等間隔で置く問い合わせ点。先頭（いまいる場所）は入れない。
    /// 目の前の天気は窓を見れば分かる。
    private static func samples(of route: NavRoute) -> [CLLocationCoordinate2D] {
        let coordinates = route.coordinates
        guard coordinates.count > sampleCount else { return coordinates }

        let stride = coordinates.count / (sampleCount + 1)
        return (1 ... sampleCount).compactMap { index in
            let position = stride * index
            return coordinates.indices.contains(position) ? coordinates[position] : nil
        }
    }
}
