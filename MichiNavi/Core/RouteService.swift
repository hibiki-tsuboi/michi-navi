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
    /// 中身から作る指紋。**引き直した結果が前とまったく同じ経路かどうか**を見分ける。
    ///
    /// `id` は生成のたびに変わるので、同じ道を同じ順に曲がる経路でも別物になる。
    /// 引き直しを「`id` が変わったこと」で判定している側（`VoiceGuidance`）は、それを
    /// リルートとみなして「ルートを再検索しました」を読み上げてしまう。停まったまま
    /// 引き直すと入力が同じ＝毎回同じ経路が返るので、**同じ経路を繰り返し
    /// 「再検索しました」と読み上げる**という、いちばん不快な形になる。
    ///
    /// 座標列ではなく step の指示と距離で作る。座標は数千点あって毎回舐めると重く、
    /// 同じ道をたどるなら指示と距離も必ず一致する。
    var signature: Int {
        var hasher = Hasher()
        hasher.combine(destination.id)
        for step in steps {
            hasher.combine(step.instruction)
            hasher.combine(Int(step.distance.rounded()))
        }
        return hasher.finalize()
    }

    /// `stepIndex` の区間の始まりから先の座標列。まだ通っていない部分を指す。
    /// ルート沿いに施設を探すときの範囲になる。
    func remainingCoordinates(from stepIndex: Int) -> [CLLocationCoordinate2D] {
        guard stepIndex > 0, stepEndIndices.indices.contains(stepIndex - 1) else { return coordinates }

        let start = stepEndIndices[stepIndex - 1]
        guard coordinates.indices.contains(start) else { return coordinates }
        return Array(coordinates[start...])
    }

    /// 先頭から `distance` メートルぶんの座標列。
    /// 「ここまでなら届く」範囲を切り出して、その中だけを探すために使う。
    static func coordinates(_ coordinates: [CLLocationCoordinate2D],
                            upTo distance: CLLocationDistance) -> [CLLocationCoordinate2D] {
        guard let first = coordinates.first, distance > 0 else { return [] }

        var result = [first]
        var travelled: CLLocationDistance = 0
        var previous = MKMapPoint(first)

        for coordinate in coordinates.dropFirst() {
            let point = MKMapPoint(coordinate)
            travelled += point.distance(to: previous)
            previous = point
            guard travelled <= distance else { break }
            result.append(coordinate)
        }
        return result
    }
}

enum RouteError: LocalizedError {
    case noRouteFound

    var errorDescription: String? {
        switch self {
        case .noRouteFound: String(localized: "ルートが見つかりませんでした")
        }
    }
}

/// ルート計算の差し替え口。いまは MapKit 実装だけだが、
/// 将来 Mapbox / Valhalla などに乗り換えるときはここだけ差し替える。
protocol RouteProviding: AnyObject {
    func routes(from origin: CLLocationCoordinate2D,
                via waypoints: [Place],
                to destination: Place) async throws -> [NavRoute]

    /// **その時刻に着くつもりで走った場合の**所要時間。
    ///
    /// いまの所要時間とは別物。経路提供側は到着時刻から道路の混み具合を見積もるので、
    /// 朝の 9 時着と深夜 2 時着では返る値が違う。
    func travelTime(from origin: CLLocationCoordinate2D,
                    to destination: Place,
                    arrivingBy date: Date) async throws -> TimeInterval

    /// **いま出発した場合の**所要時間。案内中に到着予定を測り直すために使う。
    ///
    /// `routes` と違って経路の形は返さない。走行中に経路そのものを差し替えると音声も
    /// 案内カードも追随できないので、**動かしてよいのは数字だけ**。
    func travelTime(from origin: CLLocationCoordinate2D,
                    via waypoints: [Place],
                    to destination: Place) async throws -> TimeInterval
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

    func travelTime(from origin: CLLocationCoordinate2D,
                    to destination: Place,
                    arrivingBy date: Date) async throws -> TimeInterval {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: origin.latitude, longitude: origin.longitude),
                                   address: nil)
        request.destination = destination.mapItem
        request.transportType = .automobile
        request.tollPreference = RoutePreferences.shared.tollPreference
        request.highwayPreference = RoutePreferences.shared.highwayPreference
        // これを渡すと、いまの交通量ではなく**その時刻の見込み**で計算される。
        request.arrivalDate = date

        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else { throw RouteError.noRouteFound }
        return route.expectedTravelTime
    }

    func travelTime(from origin: CLLocationCoordinate2D,
                    via waypoints: [Place],
                    to destination: Place) async throws -> TimeInterval {
        // `arrivalDate` を渡さないので、いまの交通量で計算される。測り直しの狙いはそこ。
        var source = MKMapItem(location: CLLocation(latitude: origin.latitude, longitude: origin.longitude),
                               address: nil)
        var total: TimeInterval = 0

        // 経由地があると区間の数だけ問い合わせが要る。呼ぶ間隔はそれを前提に決めること
        // （`NavigationController.travelTimeRefreshInterval`）。
        for place in waypoints + [destination] {
            guard let leg = try await legs(from: source, to: place.mapItem, alternates: false).first else {
                throw RouteError.noRouteFound
            }
            total += leg.expectedTravelTime
            source = place.mapItem
        }
        return total
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
            // `compactMap(NavStep.init(step:))` と書かないこと。関数として渡すと
            // MainActor の隔離が落ちる（既定で全部が MainActor）。
            steps.append(contentsOf: leg.steps.compactMap { NavStep(step: $0) })
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
