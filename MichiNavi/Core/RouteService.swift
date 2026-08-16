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
///
/// 経由地があっても 1 本の経路として持つ。区間ごとに引いた結果をここで繋いでしまうので、
/// `GuidanceEngine` も `VoiceGuidance` も経由地を知らないまま動く。
struct NavRoute: Identifiable {
    let id = UUID()
    let name: String
    let distance: CLLocationDistance
    let expectedTravelTime: TimeInterval
    let polyline: MKPolyline
    let steps: [NavStep]
    let advisoryNotices: [String]
    let destination: Place

    /// 立ち寄り先。並んでいる順に通ってから目的地へ向かう。
    let waypoints: [Place]
    /// 各経由地に着く step の添字。`waypoints` と同じ数だけ並ぶ。
    /// リルート時に「まだ通っていない経由地」を選び直すのに使う。
    let waypointStepIndices: [Int]

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
    func routes(from origin: CLLocationCoordinate2D,
                via waypoints: [Place],
                to destination: Place) async throws -> [NavRoute]
}

final class MapKitRouteProvider: RouteProviding {
    func routes(from origin: CLLocationCoordinate2D,
                via waypoints: [Place],
                to destination: Place) async throws -> [NavRoute] {
        let source = MKMapItem(location: CLLocation(latitude: origin.latitude, longitude: origin.longitude),
                               address: nil)

        // 経由地が無いときだけ候補を複数返す。選ばせる意味があるのはこの場合だけで、
        // 経由地があると区間の数だけ組み合わせが増えて選べる形にならない。
        guard !waypoints.isEmpty else {
            return try await legs(from: source, to: destination.mapItem, alternates: true)
                .map { NavRoute(legs: [$0], waypoints: [], destination: destination) }
        }

        // MKDirections は経由地を扱えないので、区間ごとに引いて繋ぐ。
        var stitched: [MKRoute] = []
        var from = source
        for place in waypoints + [destination] {
            guard let leg = try await legs(from: from, to: place.mapItem, alternates: false).first else {
                throw RouteError.noRouteFound
            }
            stitched.append(leg)
            from = place.mapItem
        }
        return [NavRoute(legs: stitched, waypoints: waypoints, destination: destination)]
    }

    private func legs(from source: MKMapItem,
                      to destination: MKMapItem,
                      alternates: Bool) async throws -> [MKRoute] {
        let request = MKDirections.Request()
        request.source = source
        request.destination = destination
        request.transportType = .automobile
        request.requestsAlternateRoutes = alternates
        // **要望であって指示ではない**。避けようがない区間（離島の有料橋など）では
        // MapKit がそのまま有料道路を含む経路を返す。返ってきた経路を弾いてはいけない。
        request.tollPreference = RoutePreferences.shared.tollPreference
        request.highwayPreference = RoutePreferences.shared.highwayPreference

        let response = try await MKDirections(request: request).calculate()
        guard !response.routes.isEmpty else { throw RouteError.noRouteFound }
        return response.routes
    }
}

private extension NavRoute {
    /// 区間を繋いで 1 本の経路にする。経由地が無ければ区間は 1 つ。
    init(legs: [MKRoute], waypoints: [Place], destination: Place) {
        var steps: [NavStep] = []
        var waypointStepIndices: [Int] = []

        for (index, leg) in legs.enumerated() {
            steps.append(contentsOf: leg.steps.compactMap(NavStep.init(step:)))
            // 最後の区間の終わりは目的地なので、経由地には数えない。
            if index < legs.count - 1 { waypointStepIndices.append(max(steps.count - 1, 0)) }
        }

        // step の座標列を連結して 1 本の線にする。継ぎ目は重複するので落とす。
        var merged: [CLLocationCoordinate2D] = []
        var endIndices: [Int] = []
        for step in steps {
            let isJoin = merged.last.map { $0.isClose(to: step.coordinates[0]) } ?? false
            merged.append(contentsOf: isJoin ? Array(step.coordinates.dropFirst()) : step.coordinates)
            endIndices.append(merged.count - 1)
        }

        // 描画用の線は MKRoute のものをそのまま使う。step から組み直したものより細かい。
        let shape: MKPolyline
        if let only = legs.first, legs.count == 1 {
            shape = only.polyline
        } else {
            let joined = legs.flatMap(\.polyline.coordinates)
            shape = MKPolyline(coordinates: joined, count: joined.count)
        }

        self.init(name: legs.first?.name ?? "",
                  distance: legs.reduce(0) { $0 + $1.distance },
                  expectedTravelTime: legs.reduce(0) { $0 + $1.expectedTravelTime },
                  polyline: shape,
                  steps: steps,
                  advisoryNotices: legs.flatMap(\.advisoryNotices),
                  destination: destination,
                  waypoints: waypoints,
                  waypointStepIndices: waypointStepIndices,
                  coordinates: merged,
                  stepEndIndices: endIndices)
    }
}

private extension NavStep {
    init?(step: MKRoute.Step) {
        let coordinates = step.polyline.coordinates
        // MapKit は先頭に距離 0 の「出発します」ダミー区間を返すことがある。
        guard coordinates.count >= 2 else { return nil }

        self.init(instruction: step.instructions,
                  notice: step.notice,
                  distance: step.distance,
                  coordinates: coordinates)
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
