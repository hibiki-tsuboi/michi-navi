import CoreLocation
import Testing
@testable import MichiNavi

/// 行き先を決めず、時間から現在地へ戻る候補を作る探索ドライブ。
@MainActor
struct ExplorationDriveTests {
    @Test("30・60・90分を選べる")
    func offersThreeDurations() {
        #expect(ExplorationDrive.durationOptions == [1_800, 3_600, 5_400])
    }

    @Test("目標時間から4方向に2つずつ通過点を作る")
    func makesFourDirectionalPlans() {
        let plans = ExplorationDrive.plans(from: SyntheticRoute.origin, targetDuration: 3_600)

        #expect(plans.count == 4)
        #expect(plans.allSatisfy { $0.waypoints.count == 2 })
        let origin = CLLocation(latitude: SyntheticRoute.origin.latitude,
                                longitude: SyntheticRoute.origin.longitude)
        let distances = plans.flatMap(\.waypoints).map {
            origin.distance(from: CLLocation(latitude: $0.coordinate.latitude,
                                             longitude: $0.coordinate.longitude))
        }
        #expect(distances.allSatisfy { (12_000 ... 13_000).contains($0) })
    }

    @Test("初めての道の多さと時間の近さを合わせて候補を並べる")
    func ranksNoveltyWithoutIgnoringDuration() {
        var balanced = route(instruction: "東へ", duration: 3_600)
        balanced.newRoadPercentage = 70
        var tooLong = route(instruction: "西へ", duration: 7_200)
        tooLong.newRoadPercentage = 100
        var familiar = route(instruction: "南へ", duration: 3_600)
        familiar.newRoadPercentage = 40

        let ranked = ExplorationDrive.ranked([tooLong, familiar, balanced], targetDuration: 3_600)

        #expect(ranked.map(\.id) == [balanced.id, tooLong.id, familiar.id])
    }

    @Test("探索用の通過点は立ち寄り先として見せない")
    func hidesShapingWaypoints() {
        let base = route(instruction: "北へ", duration: 3_600)
        let waypoint = SyntheticRoute.place("内部点", at: SyntheticRoute.coordinate(north: 500))
        let userStop = SyntheticRoute.place("休憩所", at: SyntheticRoute.coordinate(north: 700))
        var exploration = NavRoute(name: base.name,
                                   distance: base.distance,
                                   expectedTravelTime: base.expectedTravelTime,
                                   polyline: base.polyline,
                                   steps: base.steps,
                                   advisoryNotices: base.advisoryNotices,
                                   destination: base.destination,
                                   waypoints: [waypoint, userStop],
                                   waypointStepIndices: [0, 0],
                                   coordinates: base.coordinates,
                                   stepEndIndices: base.stepEndIndices)
        #expect(exploration.displayedWaypoints.count == 2)

        exploration.explorationDuration = 3_600
        exploration.hiddenWaypointIDs = [waypoint.id]

        #expect(exploration.displayedWaypoints.map(\.id) == [userStop.id])
        #expect(exploration.waypoints.count == 2)
    }

    private func route(instruction: String, duration: TimeInterval) -> NavRoute {
        SyntheticRoute.straight([("", 0), (instruction, 1_000)], expectedTravelTime: duration)
    }
}
