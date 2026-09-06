import CoreLocation

/// 車の前方にある名所を短く紹介する。地図上の近さだけで「右手」と言わないための判定。
struct SightseeingGuide {
    enum Side: Equatable { case left, right }

    struct Notice {
        let spot: SightseeingSpot
        let side: Side
    }

    private var announced: [SightseeingSpot] = []
    private var lastAnnouncement: Date?

    /// 市街地で施設の数だけ喋り続けない。案内を引き直しても、この記録は捨てない。
    static let minimumInterval: TimeInterval = 180

    mutating func notice(near location: CLLocation, spots: [SightseeingSpot], now: Date,
                         hasActiveRoute: Bool, progress: RouteProgress?, isRerouting: Bool) -> Notice? {
        guard Self.usable(location, now: now), !isRerouting else { return nil }
        if hasActiveRoute {
            // 出発直後・逸脱中・到着直前は、距離が長くても運転の案内を優先する。
            guard let progress, progress.hasJoinedRoute, !progress.isOffRoute, !progress.hasArrived,
                  progress.distanceToNextManeuver > max(500, location.speed * 25) else { return nil }
        }
        if let lastAnnouncement, now.timeIntervalSince(lastAnnouncement) < Self.minimumInterval { return nil }

        let candidates = spots.compactMap { spot -> (Notice, CLLocationDistance)? in
            guard !announced.contains(where: { $0.isSamePlace(as: spot) }),
                  let side = Self.side(of: spot.coordinate, from: location) else { return nil }
            return (Notice(spot: spot, side: side), location.distance(from: spot.location))
        }
        guard let next = candidates.min(by: { $0.1 < $1.1 })?.0 else { return nil }
        // 読めなかった案内を後追いしない。通過後や折り返した後に同じ施設を紹介しない。
        announced.append(next.spot)
        lastAnnouncement = now
        return next
    }

    static func usable(_ location: CLLocation, now: Date) -> Bool {
        let age = now.timeIntervalSince(location.timestamp)
        return CLLocationCoordinate2DIsValid(location.coordinate)
            && (0...35).contains(location.horizontalAccuracy)
            && (-1...10).contains(age)
            && location.speed >= 3
            && (0..<360).contains(location.course)
            && (0...20).contains(location.courseAccuracy)
    }

    static func side(of coordinate: CLLocationCoordinate2D, from location: CLLocation) -> Side? {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let destination = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let distance = location.distance(from: destination)
        guard distance <= 300, distance >= 30 else { return nil }

        let latitude = location.coordinate.latitude * .pi / 180
        let targetLatitude = coordinate.latitude * .pi / 180
        let longitude = (coordinate.longitude - location.coordinate.longitude) * .pi / 180
        let bearing = atan2(sin(longitude) * cos(targetLatitude),
                            cos(latitude) * sin(targetLatitude)
                            - sin(latitude) * cos(targetLatitude) * cos(longitude))
        let relative = bearing - location.course * .pi / 180
        let angle = atan2(sin(relative), cos(relative)) * 180 / .pi
        // 正面や真横は、方位の誤差だけで左右・前後が入れ替わるので紹介しない。
        guard abs(angle) >= 25 + location.courseAccuracy,
              abs(angle) <= 90 - location.courseAccuracy,
              abs(sin(relative) * distance) > max(25, location.horizontalAccuracy * 2) else { return nil }
        return angle > 0 ? .right : .left
    }
}

struct SightseeingSpot {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    let detail: String?

    var location: CLLocation { CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude) }

    func isSamePlace(as other: SightseeingSpot) -> Bool {
        // 検索の種類や座標の小さな差で ID が変わっても、同じ施設を紹介し直さない。
        id == other.id || (SightseeingSearch.normalized(name) == SightseeingSearch.normalized(other.name)
                          && location.distance(from: other.location) < 100)
    }
}
