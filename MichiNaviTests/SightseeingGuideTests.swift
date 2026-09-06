import CoreLocation
import Testing
@testable import MichiNavi

@MainActor
struct SightseeingGuideTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let origin = CLLocationCoordinate2D(latitude: 35, longitude: 139)

    private func coordinate(east: Double, north: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: origin.latitude + north / 111_320,
                               longitude: origin.longitude + east / (111_320 * cos(origin.latitude * .pi / 180)))
    }

    private func location(course: Double = 0, accuracy: Double = 5, courseAccuracy: Double = 5,
                          speed: Double = 10, age: Double = 0) -> CLLocation {
        CLLocation(coordinate: origin, altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5,
                   course: course, courseAccuracy: courseAccuracy, speed: speed, speedAccuracy: 1,
                   timestamp: now.addingTimeInterval(-age))
    }

    private func spot(_ id: String = "shrine", east: Double = 100, north: Double = 100) -> SightseeingSpot {
        SightseeingSpot(id: id, name: "試験神社", coordinate: coordinate(east: east, north: north), detail: nil)
    }

    private func progress(distance: Double, joined: Bool = true, offRoute: Bool = false,
                          arrived: Bool = false) -> RouteProgress {
        RouteProgress(stepIndex: 1, distanceToNextManeuver: distance, distanceRemaining: 3000,
                      timeRemaining: 300, snappedCoordinate: origin, distanceFromRoute: 0,
                      isOffRoute: offRoute, hasArrived: arrived, hasJoinedRoute: joined)
    }

    @Test("進行方向が変われば左右も変わる", arguments: [0.0, 180.0, 359.0])
    func sidesFollowCourse(course: Double) {
        let north = course == 180 ? -100.0 : 100.0
        #expect(SightseeingGuide.side(of: coordinate(east: 100, north: north), from: location(course: course))
                == (course == 180 ? .left : .right))
        #expect(SightseeingGuide.side(of: coordinate(east: -100, north: north), from: location(course: course))
                == (course == 180 ? .right : .left))
    }

    @Test("正面・後方・離れた施設を右手の名所として紹介しない")
    func unsuitablePositionsAreSilent() {
        let loc = location()
        #expect(SightseeingGuide.side(of: coordinate(east: 10, north: 100), from: loc) == nil)
        #expect(SightseeingGuide.side(of: coordinate(east: 100, north: -100), from: loc) == nil)
        #expect(SightseeingGuide.side(of: coordinate(east: 400, north: 400), from: loc) == nil)
        #expect(SightseeingGuide.side(of: coordinate(east: 10, north: 10), from: loc) == nil)
        // 方位誤差の範囲内に真横が入るので、通過前と言い切れない。
        #expect(SightseeingGuide.side(of: coordinate(east: 150, north: 10), from: loc) == nil)
    }

    @Test("古い測位・停車中・不正確な位置や方位では喋らない")
    func uncertainLocationIsSilent() {
        let invalid = [location(age: 15), location(age: -10), location(speed: 0),
                       location(accuracy: -1), location(accuracy: 60), location(course: -1),
                       location(courseAccuracy: -1), location(courseAccuracy: 40)]
        for loc in invalid {
            var guide = SightseeingGuide()
            #expect(guide.notice(near: loc, spots: [spot()], now: now,
                                 hasActiveRoute: false, progress: nil, isRerouting: false) == nil)
        }
        #expect(SightseeingGuide.usable(location(), now: now))
    }

    @Test("GPS誤差だけで左右が逆転し得る近さでは紹介しない")
    func lateralAccuracyMatters() {
        #expect(SightseeingGuide.side(of: coordinate(east: 40, north: 50),
                                     from: location(accuracy: 30)) == nil)
        #expect(SightseeingGuide.side(of: coordinate(east: 40, north: 50),
                                     from: location(accuracy: 5)) == .right)
    }

    @Test("曲がる直前・高速走行・経路が不確かな場面では案内を優先する")
    func navigationTakesPriority() {
        let states: [(CLLocation, RouteProgress?, Bool)] = [
            (location(), progress(distance: 400), false),
            (location(speed: 30), progress(distance: 600), false),
            (location(), nil, false),
            (location(), progress(distance: 1500, joined: false), false),
            (location(), progress(distance: 1500, offRoute: true), false),
            (location(), progress(distance: 1500, arrived: true), false),
            (location(), progress(distance: 1500), true)
        ]
        for (loc, progress, rerouting) in states {
            var guide = SightseeingGuide()
            #expect(guide.notice(near: loc, spots: [spot()], now: now,
                                 hasActiveRoute: true, progress: progress, isRerouting: rerouting) == nil)
        }
        var guide = SightseeingGuide()
        #expect(guide.notice(near: location(), spots: [spot()], now: now,
                             hasActiveRoute: true, progress: progress(distance: 1500), isRerouting: false) != nil)
    }

    @Test("近い施設を一つ選び、間隔を空けても同じ施設は繰り返さない")
    func choosesOneAndDoesNotRepeat() {
        var guide = SightseeingGuide()
        let near = spot("near")
        let far = spot("far", east: -180, north: 180)
        let first = guide.notice(near: location(), spots: [far, near], now: now,
                                 hasActiveRoute: false, progress: nil, isRerouting: false)
        #expect(first?.spot.id == "near")
        #expect(guide.notice(near: location(age: -60), spots: [near, far], now: now.addingTimeInterval(60),
                             hasActiveRoute: false, progress: nil, isRerouting: false) == nil)
        #expect(guide.notice(near: location(age: -200), spots: [near], now: now.addingTimeInterval(200),
                             hasActiveRoute: false, progress: nil, isRerouting: false) == nil)
        #expect(guide.notice(near: location(age: -200), spots: [near, far], now: now.addingTimeInterval(200),
                             hasActiveRoute: false, progress: nil, isRerouting: false)?.spot.id == "far")
    }

    @Test("曲がる案内で見送った施設は、通過前なら後で紹介できる")
    func skippedTurnDoesNotConsumeSpot() {
        var guide = SightseeingGuide()
        #expect(guide.notice(near: location(), spots: [spot()], now: now, hasActiveRoute: true,
                             progress: progress(distance: 400), isRerouting: false) == nil)
        #expect(guide.notice(near: location(), spots: [spot()], now: now, hasActiveRoute: true,
                             progress: progress(distance: 2000), isRerouting: false) != nil)
    }

    @Test("再検索で識別子が変わっても同じ施設を紹介し直さない")
    func changedIdentifierDoesNotRepeat() {
        var guide = SightseeingGuide()
        #expect(guide.notice(near: location(), spots: [spot("first")], now: now,
                             hasActiveRoute: false, progress: nil, isRerouting: false) != nil)
        #expect(guide.notice(near: location(age: -240), spots: [spot("second", east: 110)],
                             now: now.addingTimeInterval(240), hasActiveRoute: false,
                             progress: nil, isRerouting: false) == nil)
    }
}
