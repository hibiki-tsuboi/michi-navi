import CoreLocation
import MapKit

/// 案内 1 区間ぶんの指示。「300m 先を右折」の "右折" にあたる部分。
struct NavStep {
    let instruction: String
    let notice: String?
    let distance: CLLocationDistance
    /// この区間の形状。連結すると経路全体になる。
    let coordinates: [CLLocationCoordinate2D]
    /// 曲がる地点＝この区間の終端。
    var maneuverCoordinate: CLLocationCoordinate2D { coordinates.last ?? kCLLocationCoordinate2DInvalid }
}

/// 計算済みの 1 経路。
struct NavRoute: Identifiable {
    let id = UUID()
    let name: String
    let distance: CLLocationDistance
    let expectedTravelTime: TimeInterval
    let polyline: MKPolyline
    let steps: [NavStep]
    let advisoryNotices: [String]
    let destination: Place

    /// 案内計算に使う経路全体の座標列（steps を連結したもの）。
    let coordinates: [CLLocationCoordinate2D]
    /// `coordinates` 上で各 step が終わる添字。
    let stepEndIndices: [Int]
}

extension NavRoute {
    /// `stepIndex` の区間の始まりから先の座標列。まだ通っていない部分を指す。
    /// ルート沿いに施設を探すときの範囲になる。
    func remainingCoordinates(from stepIndex: Int) -> [CLLocationCoordinate2D] {
        guard stepIndex > 0, stepEndIndices.indices.contains(stepIndex - 1) else { return coordinates }

        let start = stepEndIndices[stepIndex - 1]
        guard coordinates.indices.contains(start) else { return coordinates }
        return Array(coordinates[start...])
    }
}

enum RouteError: LocalizedError {
    case noRouteFound

    var errorDescription: String? {
        switch self {
        case .noRouteFound: "ルートが見つかりませんでした"
        }
    }
}

/// ルート計算の差し替え口。いまは MapKit 実装だけだが、
/// 将来 Mapbox / Valhalla などに乗り換えるときはここだけ差し替える。
protocol RouteProviding: AnyObject {
    func routes(from origin: CLLocationCoordinate2D, to destination: Place) async throws -> [NavRoute]
}

final class MapKitRouteProvider: RouteProviding {
    func routes(from origin: CLLocationCoordinate2D, to destination: Place) async throws -> [NavRoute] {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: origin.latitude, longitude: origin.longitude),
                                   address: nil)
        request.destination = destination.mapItem
        request.transportType = .automobile
        request.requestsAlternateRoutes = true

        let response = try await MKDirections(request: request).calculate()
        guard !response.routes.isEmpty else { throw RouteError.noRouteFound }

        return response.routes.map { NavRoute(route: $0, destination: destination) }
    }
}

private extension NavRoute {
    init(route: MKRoute, destination: Place) {
        let steps: [NavStep] = route.steps.compactMap { step in
            let coordinates = step.polyline.coordinates
            // MapKit は先頭に距離 0 の「出発します」ダミー区間を返すことがある。
            guard coordinates.count >= 2 else { return nil }
            return NavStep(instruction: step.instructions,
                           notice: step.notice,
                           distance: step.distance,
                           coordinates: coordinates)
        }

        // step の座標列を連結して 1 本の線にする。継ぎ目は重複するので落とす。
        var merged: [CLLocationCoordinate2D] = []
        var endIndices: [Int] = []
        for step in steps {
            let isJoin = merged.last.map { $0.isClose(to: step.coordinates[0]) } ?? false
            merged.append(contentsOf: isJoin ? Array(step.coordinates.dropFirst()) : step.coordinates)
            endIndices.append(merged.count - 1)
        }

        self.init(name: route.name,
                  distance: route.distance,
                  expectedTravelTime: route.expectedTravelTime,
                  polyline: route.polyline,
                  steps: steps,
                  advisoryNotices: route.advisoryNotices,
                  destination: destination,
                  coordinates: merged,
                  stepEndIndices: endIndices)
    }
}

extension MKMultiPoint {
    var coordinates: [CLLocationCoordinate2D] {
        var result = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&result, range: NSRange(location: 0, length: pointCount))
        return result
    }
}

extension CLLocationCoordinate2D {
    /// 継ぎ目判定用。約 10cm 以内なら同じ点とみなす。
    func isClose(to other: CLLocationCoordinate2D) -> Bool {
        abs(latitude - other.latitude) < 1e-6 && abs(longitude - other.longitude) < 1e-6
    }
}
