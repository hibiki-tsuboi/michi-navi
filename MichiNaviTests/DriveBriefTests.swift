import Foundation
import Testing
@testable import MichiNavi

/// 案内開始前のドライブブリーフ。
///
/// ルート画面にすでにある距離・所要の言い直しではなく、走行履歴、候補との差、
/// 曲がり方、日差し、注意を 1 つにまとめられていることを止める。
@MainActor
struct DriveBriefTests {
    private let night: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: 1))!
    }()

    @Test("初めての道は割合とおよその距離を持つ")
    func noveltyIncludesDistance() {
        var route = SyntheticRoute.straight([
            ("", 0),
            ("右折", 2_500),
            ("斜め右", 2_500),
            ("右車線を走行", 1_000),
            ("左折", 2_000),
            ("斜め左", 2_000),
        ])
        route.newRoadPercentage = 40

        let brief = DriveBrief.make(for: route,
                                     comparisonTags: [String(localized: "最短時間")],
                                     departure: night)

        #expect(brief.newRoadPercentage == 40)
        #expect(brief.newRoadDistance == 4_000)
        #expect(brief.rightTurns == 2)
        #expect(brief.leftTurns == 2)
        // 車線を右へ寄せるだけの指示を、右折として数えない。
        #expect(brief.items.first(where: { $0.kind == .turns }) != nil)
        #expect(brief.highlights.first == RouteNovelty.label(for: 40))
        #expect(brief.highlights.contains(String(localized: "最短時間")))
    }

    @Test("注意と日差しはブリーフの先頭に置く")
    func actionableItemsComeFirst() {
        let glare = SunGlareAdvisor.Glare(sun: .evening,
                                          start: Date(timeIntervalSince1970: 1_000),
                                          duration: 10 * 60)
        let brief = DriveBrief(newRoadPercentage: 80,
                               newRoadDistance: 8_000,
                               comparisonTags: [],
                               rightTurns: 1,
                               leftTurns: 0,
                               glare: glare,
                               advisories: ["通行料が必要です"],
                               waypointNames: ["海老名サービスエリア"])

        #expect(brief.items.map(\.kind) == [
            .advisory, .sunlight, .novelty, .turns, .waypoint,
        ])
    }

    @Test("狭い候補一覧には長い項目を持ち込まない")
    func highlightsStayCompact() {
        let brief = DriveBrief(newRoadPercentage: 60,
                               newRoadDistance: 6_000,
                               comparisonTags: [String(localized: "右折が少ない")],
                               rightTurns: 2,
                               leftTurns: 3,
                               glare: nil,
                               advisories: ["注意事項"],
                               waypointNames: ["立ち寄り先"])

        #expect(brief.highlights == [
            RouteNovelty.label(for: 60),
            String(localized: "右折が少ない"),
            "注意事項",
        ])
        #expect(brief.highlights.contains("立ち寄り先") == false)
    }

    @Test("ブリーフで見た日差しは案内開始直後に重ねない")
    func previewSuppressesDuplicateSunNotice() {
        var route = SyntheticRoute.straight([("", 0), ("直進", 10_000)])
        let glare = SunGlareAdvisor.Glare(sun: .morning,
                                          start: Date(timeIntervalSince1970: 1_000),
                                          duration: 10 * 60)
        route.driveBrief = DriveBrief(newRoadPercentage: 100,
                                      newRoadDistance: 10_000,
                                      comparisonTags: [],
                                      rightTurns: 0,
                                      leftTurns: 0,
                                      glare: glare,
                                      advisories: [],
                                      waypointNames: [])
        var gate = SunGlareAdvisor.AnnouncementGate()

        #expect(gate.routeToCheck(for: .previewing([route])) == nil)
        #expect(gate.routeToCheck(for: .navigating(route)) == nil)
    }

    @Test("提示を通らない開始では従来どおり日差しを調べる")
    func directStartStillChecksSun() {
        let route = SyntheticRoute.straight([("", 0), ("直進", 10_000)])
        var gate = SunGlareAdvisor.AnnouncementGate()

        #expect(gate.routeToCheck(for: .calculating(route.destination)) == nil)
        #expect(gate.routeToCheck(for: .navigating(route))?.id == route.id)
        // 同じ目的地の引き直しでは繰り返さない。
        #expect(gate.routeToCheck(for: .navigating(route)) == nil)
    }
}
