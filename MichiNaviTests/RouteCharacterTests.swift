import CoreLocation
import Testing
@testable import MichiNavi

/// 候補ルートに付ける短い特徴。
///
/// **守っているのは「比較から決める」という形そのもの。** 単独の候補に付く特徴は
/// 情報にならないし、同点なのに片方へ付けると選ぶ理由を誤らせる。
@MainActor
struct RouteCharacterTests {
    private func route(minutes: Double,
                       metres: CLLocationDistance,
                       instructions: [String] = ["直進"]) -> NavRoute {
        SyntheticRoute.straight([("", 0)] + instructions.map { ($0, metres / Double(instructions.count)) },
                                expectedTravelTime: minutes * 60)
    }

    @Test("候補が 1 本なら何も付けない")
    func singleRouteHasNoTags() {
        #expect(RouteCharacter.tags(for: [route(minutes: 10, metres: 5_000)]) == [[]])
    }

    @Test("いちばん良いものが 1 本のときだけ付ける")
    func tagsOnlyTheSingleBest() {
        let tags = RouteCharacter.tags(for: [route(minutes: 10, metres: 5_000),
                                             route(minutes: 14, metres: 7_000)])
        #expect(tags[0].contains(String(localized: "最短時間")))
        #expect(tags[0].contains(String(localized: "距離が短い")))
        #expect(tags[1].isEmpty)
    }

    @Test("同点なら誰にも付けない")
    func tiesGetNothing() {
        let tags = RouteCharacter.tags(for: [route(minutes: 12, metres: 6_000),
                                             route(minutes: 12, metres: 6_000)])
        #expect(tags == [[], []])
    }

    @Test("右折の少なさは他と比べて決まる")
    func fewerRightTurnsIsComparative() {
        let manyTurns = route(minutes: 10, metres: 6_000, instructions: ["右方向", "右方向", "右方向"])
        let fewTurns = route(minutes: 10, metres: 6_000, instructions: ["直進", "直進", "左方向"])
        let tags = RouteCharacter.tags(for: [manyTurns, fewTurns])
        #expect(tags[1].contains(String(localized: "右折が少ない")))
        #expect(tags[0].contains(String(localized: "右折が少ない")) == false)
    }

    @Test("高速の有無は、候補で分かれているときだけ出す")
    func highwayTagAppearsOnlyWhenItDiffers() {
        let highway = route(minutes: 10, metres: 6_000, instructions: ["首都高速入口へ"])
        let surface = route(minutes: 12, metres: 6_000, instructions: ["直進"])

        let mixed = RouteCharacter.tags(for: [highway, surface])
        #expect(mixed[0].contains(String(localized: "高速を使う")))
        #expect(mixed[1].contains(String(localized: "下道のみ")))

        // 全部が高速なら違いにならないので出さない。
        let both = RouteCharacter.tags(for: [highway, highway])
        let mentionsHighway = both.contains { $0.contains(String(localized: "高速を使う")) }
        #expect(mentionsHighway == false)
    }

    @Test("カーブの多さは距離で割って比べる（遠回りが必ず「カーブが多い」にならない）")
    func curvatureIsPerKilometre() {
        // **合計では長いほうが勝ち、1km あたりでは短いほうが勝つ**ように組んである。
        // 25km を緩く曲がり続ける道（合計 約50 rad ／ 約2 rad/km）と、
        // 2km で鋭く折れ曲がる道（合計 約39 rad ／ 約20 rad/km）。
        // 距離で割るのをやめると、前者が「カーブが多い」になる（＝このテストが落ちる）。
        let longWithGentleCurves = SyntheticRoute.shaped((0 ... 250).map {
            SyntheticRoute.coordinate(north: Double($0) * 100,
                                      east: $0.isMultiple(of: 2) ? 5 : -5)
        })
        let shortAndWinding = SyntheticRoute.shaped((0 ... 20).map {
            SyntheticRoute.coordinate(north: Double($0) * 50,
                                      east: $0.isMultiple(of: 2) ? 40 : -40)
        })

        let tags = RouteCharacter.tags(for: [longWithGentleCurves, shortAndWinding])
        #expect(tags[1].contains(String(localized: "カーブが多い")))
        #expect(tags[0].contains(String(localized: "カーブが多い")) == false)
    }
}
