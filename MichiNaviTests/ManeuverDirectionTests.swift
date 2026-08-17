import Testing
@testable import MichiNavi

/// 指示文から曲がる向きを推測する表。
///
/// **ここで決めた向きは画面のアイコンだけでなく `CPManeuver.maneuverType` として
/// 車のメーター・HUD へも送られる**ので、外すと両方が同時にずれる。守っているのは
/// 個々の語ではなく**並び順**で、規則は 2 つ（長い語を先に置く／道路名に現れる語を入れない）。
struct ManeuverDirectionTests {
    @Test("長い語を短い語より先に見る", arguments: [
        ("斜め右方向", ManeuverDirection.slightRight),
        ("斜め左方向", .slightLeft),
        // 「ロータリー」が「出口」より後ろだと、これが高速の出口になる。
        ("ロータリーで2番目の出口", .roundabout),
        ("2番目の出口で出る", .offRamp),
    ])
    func longerKeywordsWin(instruction: String, expected: ManeuverDirection) {
        #expect(ManeuverDirection.inferred(from: instruction) == expected)
    }

    @Test("車線の指示は曲がる指示より先（分岐の手前でハンドルを切らせない）")
    func laneKeepingBeatsTurning() {
        #expect(ManeuverDirection.inferred(from: "右車線を走行して環八通りへ") == .keepRight)
        #expect(ManeuverDirection.inferred(from: "左車線を走行 都道412号へ") == .keepLeft)
    }

    @Test("ただし高速の入口・出口のほうが主（車線の指示より前に見る）")
    func rampBeatsLaneKeeping() {
        #expect(ManeuverDirection.inferred(from: "池尻ランプで右車線を走行 首都高速入口へ") == .onRamp)
        #expect(ManeuverDirection.inferred(from: "渋谷ランプで出口（玉川通り方面）") == .offRamp)
    }

    @Test("道路名に現れる語でロータリーにしない")
    func roadNamesAreNotRoundabouts() {
        // 「環状」を入れていたときは、これが `.enterRoundabout` として車の HUD へ
        // 送られていた（2026-08-16 に横浜で実測）。日本の道路名には普通に入る語なので、
        // 「環状交差点」まで絞ってある。
        #expect(ManeuverDirection.inferred(from: "環状1号を右方向") == .right)
        #expect(ManeuverDirection.inferred(from: "環状八号線を直進します") == .straight)
        #expect(ManeuverDirection.inferred(from: "環状交差点で2番目の出口") == .roundabout)
    }

    @Test("「駐車を準備」は到着に寄せる（徒歩ぶんを落としたいま最後の指示になる）")
    func parkingCountsAsArrival() {
        #expect(ManeuverDirection.inferred(from: "駐車を準備") == .arrive)
    }

    @Test("英語の指示文も同じ表で読む", arguments: [
        ("Turn right onto Main Street", ManeuverDirection.right),
        ("Turn left onto N De Anza Blvd.", .left),
        ("Keep right onto CA-85 N", .keepRight),
        ("Make a U-turn", .uTurn),
        ("Continue on I-280 S", .straight),
        ("At the roundabout, take the 2nd exit", .roundabout),
    ])
    func readsEnglish(instruction: String, expected: ManeuverDirection) {
        #expect(ManeuverDirection.inferred(from: instruction) == expected)
    }

    @Test("読めない指示文は unknown（無理に当てない）")
    func unknownStaysUnknown() {
        #expect(ManeuverDirection.inferred(from: "") == .unknown)
    }
}
