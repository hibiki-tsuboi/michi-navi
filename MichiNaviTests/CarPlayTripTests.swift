import CarPlay
import CoreLocation
import Foundation
import MapKit
import Testing
@testable import MichiNavi

/// 実際に CPTrip を作り、車への接続なしでも目的地名の API 互換性を検証する。
@MainActor
struct CarPlayTripTests {
    @Test("ルート候補の生成で落ちずに目的地名と座標を車へ渡せる")
    func createsTrip() throws {
        let route = makeRoute(name: "東京駅")
        let trip = CarPlayCoordinator.makeTrip(for: [route])

        #expect(destinationNames(of: trip) == ["東京駅"])
        #expect(trip.routeChoices.count == 1)
        #expect(trip.routeChoices.first?.userInfo as? UUID == route.id)
        if #available(iOS 26.1, *) {
            #expect(trip.hasShareableDestination)
        }
        if #available(iOS 26.4, *) {
            #expect(trip.destinationWaypoint.centerPoint.latitude == route.destination.coordinate.latitude)
            #expect(trip.destinationWaypoint.centerPoint.longitude == route.destination.coordinate.longitude)
        }

        // CarPlay へ転送するためのシリアライズでも表示名が失われないこと。
        let data = try NSKeyedArchiver.archivedData(withRootObject: trip, requiringSecureCoding: true)
        let decoded = try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: CPTrip.self, from: data))
        #expect(destinationNames(of: decoded) == ["東京駅"])
    }

    @Test("保存済み地点と名前のない地点にも目的地名が付く", arguments: ["自宅", ""])
    func restoresDestinationName(name: String) throws {
        let route = makeRoute(name: name)
        let saved = try JSONDecoder().decode(Place.self, from: JSONEncoder().encode(route.destination))
        #expect(saved.name == name)
        let trip = CarPlayCoordinator.makeTrip(for: [makeRoute(destination: saved)])

        #expect(destinationNames(of: trip) == [name.isEmpty ? String(localized: "目的地") : name])
    }

    @Test("探索ドライブの目的地名と共有の扱いを保つ")
    func namesExplorationTrip() {
        var route = makeRoute(name: "出発地点")
        route.explorationDuration = 3_600
        let trip = CarPlayCoordinator.makeTrip(for: [route])

        #expect(destinationNames(of: trip) == [String(localized: "探索ドライブ")])
        if #available(iOS 26.1, *) {
            #expect(!trip.hasShareableDestination)
        }
    }

    private func destinationNames(of trip: CPTrip) -> [String]? {
        if #available(iOS 27.0, *) {
            return trip.destinationWaypoint.nameVariants
        }
        return trip.destinationNameVariants
    }

    private func makeRoute(name: String) -> NavRoute {
        let item = MKMapItem(location: CLLocation(latitude: 35.01, longitude: 139), address: nil)
        item.name = name
        return makeRoute(destination: Place(mapItem: item))
    }

    private func makeRoute(destination: Place) -> NavRoute {
        let base = SyntheticRoute.straight([("", 0), ("直進", 1_000)])
        return NavRoute(name: base.name,
                        distance: base.distance,
                        expectedTravelTime: base.expectedTravelTime,
                        polyline: base.polyline,
                        steps: base.steps,
                        advisoryNotices: [],
                        destination: destination,
                        waypoints: [],
                        waypointStepIndices: [],
                        coordinates: base.coordinates,
                        stepEndIndices: base.stepEndIndices)
    }
}
