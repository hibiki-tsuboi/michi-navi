import CoreLocation
import Foundation
import MapKit
import Testing
@testable import MichiNavi

/// 候補ルートの「初めての道」の割合。
///
/// 距離だけで照合すると交差道路を、向きだけで照合すると離れた平行道路を走行済みにする。
/// 両方の条件を別々に壊したときに落ちる形で止める。
@MainActor
struct RouteNoveltyTests {
    private let route = SyntheticRoute.straight([("", 0), ("直進", 1_000)], spacing: 10)

    private func track(_ coordinates: [CLLocationCoordinate2D]) -> TrackStore.Track {
        let points = coordinates.map(MKMapPoint.init)
        let distance = zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        return TrackStore.Track(started: Date(timeIntervalSince1970: 0),
                                coordinates: coordinates,
                                distance: distance)
    }

    @Test("履歴が無ければ全区間が初めて")
    func emptyHistoryIsAllNew() {
        #expect(RouteNovelty.percentage(for: route, tracks: []) == 100)
    }

    @Test("同じ道を走っていれば初めての区間は無い")
    func identicalTrackIsNotNew() {
        #expect(RouteNovelty.percentage(for: route, tracks: [track(route.coordinates)]) == 0)
    }

    @Test("反対方向に走った履歴も同じ道として数える")
    func reverseDirectionIsTheSameRoad() {
        #expect(RouteNovelty.percentage(for: route,
                                        tracks: [track(Array(route.coordinates.reversed()))]) == 0)
    }

    @Test("半分だけ走った履歴なら、およそ半分が初めて")
    func halfHistoryIsHalfNew() {
        let halfway = route.coordinates.filter { $0.latitude <= SyntheticRoute.coordinate(north: 500).latitude }
        let percentage = RouteNovelty.percentage(for: route, tracks: [track(halfway)])
        #expect((45 ... 55).contains(percentage))
    }

    @Test("近い平行道路は同じ道、離れた平行道路は別の道")
    func distanceSeparatesParallelRoads() {
        let near = route.coordinates.map {
            SyntheticRoute.coordinate(
                north: ($0.latitude - SyntheticRoute.origin.latitude) * SyntheticRoute.metersPerDegreeLatitude,
                east: 20
            )
        }
        let far = route.coordinates.map {
            SyntheticRoute.coordinate(
                north: ($0.latitude - SyntheticRoute.origin.latitude) * SyntheticRoute.metersPerDegreeLatitude,
                east: 80
            )
        }

        #expect(RouteNovelty.percentage(for: route, tracks: [track(near)]) == 0)
        #expect(RouteNovelty.percentage(for: route, tracks: [track(far)]) == 100)
    }

    @Test("交差しただけの道路は走行済みにしない")
    func crossingRoadIsNotTheSameRoad() {
        let crossing = stride(from: -500.0, through: 500.0, by: 10).map {
            SyntheticRoute.coordinate(north: 500, east: $0)
        }
        #expect(RouteNovelty.percentage(for: route, tracks: [track(crossing)]) == 100)
    }
}
