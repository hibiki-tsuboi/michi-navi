import Testing
@testable import MichiNavi

/// 指示文から道路番号を取り出す表。標識の絵（`RoadShieldImage`）の入力になる。
///
/// **長い語を先に置く**という規則がここでも効く。「首都高速3号」を「高速」より先に
/// 見ないと都市高速が拾えない。
struct RoadNumberTests {
    @Test("番号を持つ道を見分ける", arguments: [
        ("国道156号を右方向", RoadNumber.national(156)),
        ("県道45号を左方向", .prefectural(45)),
        ("都道412号へ", .prefectural(412)),
        ("首都高速3号線に入ります", .expressway(3)),
        ("阪神高速11号を直進", .expressway(11)),
    ])
    func findsNumberedRoads(instruction: String, expected: RoadNumber) {
        #expect(RoadNumber.first(in: instruction)?.road == expected)
    }

    @Test("拾った範囲は指示文の中のその部分を指す（標識に差し替えるため）")
    func rangeCoversTheNumber() {
        let instruction = "国道156号を右方向"
        let found = RoadNumber.first(in: instruction)
        #expect(found.map { String(instruction[$0.range]) } == "国道156号")
    }

    @Test("番号を持たない道からは拾わない", arguments: [
        "環八通りを直進",
        "百万石通りを左方向",
        "右車線を走行",
        "高速道路に入る",
        "Turn right onto Main Street",
    ])
    func skipsUnnumberedRoads(instruction: String) {
        #expect(RoadNumber.first(in: instruction) == nil)
    }
}
