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
        let analysis = RouteNovelty.analyses(for: [route], tracks: [])[0]

        #expect(analysis.percentage == 100)
        #expect(analysis.profile.stretches.count == 1)
        #expect(abs(analysis.profile.stretches[0].startDistance) < 1)
        #expect(abs(analysis.profile.stretches[0].endDistance - 1_000) < 5)
        #expect(analysis.profile.approaching(remaining: 1_000, within: 500)?.distance == 0)

        guard case let .exploring(distance)? = analysis.profile.progress(remaining: 800) else {
            Issue.record("初めての区間内では走行距離を返す")
            return
        }
        #expect((195 ... 205).contains(distance))
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

    @Test("次のまとまった初めての道までの距離と、入ってからの走行距離を返す")
    func profileTracksApproachAndExploration() {
        let halfway = route.coordinates.filter {
            $0.latitude <= SyntheticRoute.coordinate(north: 500).latitude
        }
        let profile = RouteNovelty.analyses(for: [route], tracks: [track(halfway)])[0].profile

        #expect(profile.stretches.count == 1)
        guard case let .approaching(distance)? = profile.progress(remaining: 1_000) else {
            Issue.record("区間の手前では接近距離を返す")
            return
        }
        #expect((450 ... 600).contains(distance))
        #expect(profile.approaching(remaining: 1_000, within: 100) == nil)
        #expect(profile.approaching(remaining: 1_000, within: 600) != nil)

        guard case let .exploring(explored)? = profile.progress(remaining: 200) else {
            Issue.record("区間内では初めての道の走行距離を返す")
            return
        }
        #expect(explored > 200)
    }

    @Test("200m 未満の履歴の抜けは通知対象にしない")
    func shortUnmatchedGapIsIgnored() {
        let first = route.coordinates.filter {
            $0.latitude <= SyntheticRoute.coordinate(north: 400).latitude
        }
        let second = route.coordinates.filter {
            $0.latitude >= SyntheticRoute.coordinate(north: 550).latitude
        }
        let analysis = RouteNovelty.analyses(for: [route], tracks: [track(first), track(second)])[0]

        // 候補の割合には生の差分を残すが、走行中に細かな GPS の抜けを知らせない。
        #expect(analysis.percentage > 0)
        #expect(analysis.profile.stretches.isEmpty)
    }

    @Test("初めての区間に挟まれた100m以下の既知道路は一続きにする")
    func shortKnownGapIsBridged() {
        let knownGap = stride(from: 480.0, through: 520.0, by: 10).map {
            SyntheticRoute.coordinate(north: $0)
        }
        let profile = RouteNovelty.analyses(for: [route], tracks: [track(knownGap)])[0].profile

        #expect(profile.stretches.count == 1)
        #expect(abs(profile.stretches[0].startDistance) < 1)
        #expect(abs(profile.stretches[0].endDistance - 1_000) < 5)
    }

    @Test("経路へ合流してから一度だけ知らせ、リルート後の同じ道は知らせない")
    func announcementGateDeduplicatesAcrossReroutes() {
        let original = RouteNovelty.Profile.Stretch(
            startDistance: 0,
            endDistance: 300,
            startCoordinate: SyntheticRoute.coordinate(north: 0)
        )
        let nearbyAfterReroute = RouteNovelty.Profile.Stretch(
            startDistance: 250,
            endDistance: 550,
            startCoordinate: SyntheticRoute.coordinate(north: 100)
        )
        let differentRoad = RouteNovelty.Profile.Stretch(
            startDistance: 700,
            endDistance: 1_000,
            startCoordinate: SyntheticRoute.coordinate(north: 300)
        )
        var gate = RouteNovelty.AnnouncementGate()

        let beforeJoining = gate.shouldAnnounce(original, hasJoinedRoute: false)
        let firstAnnouncement = gate.shouldAnnounce(original, hasJoinedRoute: true)
        let repeated = gate.shouldAnnounce(original, hasJoinedRoute: true)
        let nearby = gate.shouldAnnounce(nearbyAfterReroute, hasJoinedRoute: true)
        let different = gate.shouldAnnounce(differentRoad, hasJoinedRoute: true)

        #expect(!beforeJoining)
        #expect(firstAnnouncement)
        #expect(!repeated)
        #expect(!nearby)
        #expect(different)
    }
}
