import CoreLocation
import MapKit

/// 行き先を決めず、現在地へ戻る探索ドライブの候補を組み立てる。
///
/// MapKit には「所要時間だけを指定した周回ルート」が無い。そのため、目標時間から周回の
/// 大きさを決め、方角を変えた 4 組の通過点を作る。実際の道路に沿った時間は
/// `MapKitRouteProvider` が返すので、最後に時間のずれと初めての道の多さで並べ直す。
enum ExplorationDrive {
    static let durationOptions: [TimeInterval] = [30 * 60, 60 * 60, 90 * 60]

    struct Plan {
        let waypoints: [Place]
    }

    /// 現在地の北・東・南・西へ広がる 4 候補。
    static func plans(from origin: CLLocationCoordinate2D,
                      targetDuration: TimeInterval) -> [Plan] {
        let radius = loopRadius(for: targetDuration)
        return [0.0, 90.0, 180.0, 270.0].map { heading in
            let first = coordinate(from: origin, bearing: heading - 52, distance: radius)
            let second = coordinate(from: origin, bearing: heading + 52, distance: radius)
            return Plan(waypoints: [
                place(at: first, name: String(localized: "探索ポイント1")),
                place(at: second, name: String(localized: "探索ポイント2"))
            ])
        }
    }

    static func startPlace(at coordinate: CLLocationCoordinate2D) -> Place {
        place(at: coordinate, name: String(localized: "出発地点"))
    }

    /// 「初めての道」を主役にしつつ、選んだ時間から大きく外れる候補は下げる。
    ///
    /// 初めての道が 40 ポイント多くても、所要時間が目標の 2 倍なら逆転する重み。
    /// 同じ道路を返した候補は指紋で 1 本にまとめ、画面には上位 3 本だけを出す。
    static func ranked(_ routes: [NavRoute],
                       targetDuration: TimeInterval,
                       limit: Int = 3) -> [NavRoute] {
        var signatures = Set<Int>()
        let unique = routes.filter { signatures.insert($0.signature).inserted }

        return unique.sorted { left, right in
            let leftScore = score(left, targetDuration: targetDuration)
            let rightScore = score(right, targetDuration: targetDuration)
            if leftScore != rightScore { return leftScore > rightScore }

            let leftDifference = abs(left.expectedTravelTime - targetDuration)
            let rightDifference = abs(right.expectedTravelTime - targetDuration)
            if leftDifference != rightDifference { return leftDifference < rightDifference }
            return left.distance < right.distance
        }
        .prefix(max(limit, 0))
        .map { $0 }
    }

    private static func score(_ route: NavRoute, targetDuration: TimeInterval) -> Double {
        let novelty = Double(route.newRoadPercentage ?? 0)
        guard targetDuration > 0 else { return novelty }
        let relativeDifference = abs(route.expectedTravelTime - targetDuration) / targetDuration
        return novelty - min(relativeDifference, 2) * 40
    }

    /// 市街地と郊外の中間として 45km/h を置き、三角形に近い周回の辺長から半径を逆算する。
    /// 近すぎる通過点は同じ幹線へ吸われやすく、遠すぎると 90 分が長距離旅行になるため上限も持つ。
    private static func loopRadius(for duration: TimeInterval) -> CLLocationDistance {
        let expectedDistance = max(duration, 0) * 45_000 / 3_600
        return min(max(expectedDistance / 3.6, 2_500), 30_000)
    }

    /// 球面上で、始点から方位と距離を指定した地点を求める。
    private static func coordinate(from origin: CLLocationCoordinate2D,
                                   bearing: CLLocationDirection,
                                   distance: CLLocationDistance) -> CLLocationCoordinate2D {
        let earthRadius = 6_371_000.0
        let angularDistance = distance / earthRadius
        let bearingRadians = bearing * .pi / 180
        let latitude = origin.latitude * .pi / 180
        let longitude = origin.longitude * .pi / 180

        let destinationLatitude = asin(
            sin(latitude) * cos(angularDistance)
                + cos(latitude) * sin(angularDistance) * cos(bearingRadians)
        )
        let destinationLongitude = longitude + atan2(
            sin(bearingRadians) * sin(angularDistance) * cos(latitude),
            cos(angularDistance) - sin(latitude) * sin(destinationLatitude)
        )
        let normalizedLongitude = (destinationLongitude * 180 / .pi + 540)
            .truncatingRemainder(dividingBy: 360) - 180

        return CLLocationCoordinate2D(latitude: destinationLatitude * 180 / .pi,
                                      longitude: normalizedLongitude)
    }

    private static func place(at coordinate: CLLocationCoordinate2D, name: String) -> Place {
        Place(mapItem: MKMapItem(location: CLLocation(latitude: coordinate.latitude,
                                                      longitude: coordinate.longitude),
                                 address: nil),
              fallbackName: name)
    }
}
