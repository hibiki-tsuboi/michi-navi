import Testing
@testable import MichiNavi

/// 指示文から道路名を拾う表。
///
/// **表を触るときは必ずここを通すこと。** 落ちるぶんには車が道路名を出さないだけだが、
/// 関係のない語を拾うと**車のメーター・HUD に嘘が出る**。下の 2 件はどちらも実際に
/// 出てしまった誤りで、規則（ひらがなを名前に含めない／語尾は「線」ではなく「号線」）は
/// これを塞ぐために入っている。
struct RoadNameTests {
    @Test("道路名を拾う", arguments: [
        ("国道156号を右方向に進みます", "国道156号"),
        ("県道45号を左方向", "県道45号"),
        ("首都高速3号線に入ります", "首都高速3号"),
        ("市役所前で左方向 百万石通り", "百万石通り"),
        ("交差点を右折して環八通り", "環八通り"),
        ("環状八号線を直進します", "環状八号線"),
        ("東名高速道路に入ります", "東名高速道路"),
        ("中央自動車道に入ります", "中央自動車道"),
        ("246号バイパスを右方向", "246号バイパス"),
        ("伊豆スカイラインへ", "伊豆スカイライン"),
        ("日光街道を左方向", "日光街道"),
        ("Turn right onto Main Street", "Main Street"),
        ("Continue on I-280 S", "I-280 S"),
        ("Turn left onto N De Anza Blvd.", "N De Anza Blvd"),
        ("Keep right onto CA-85 N", "CA-85 N"),
    ])
    func findsRoadName(instruction: String, expected: String) {
        #expect(RoadName.first(in: instruction) == expected)
    }

    @Test("道路名を持たない指示文からは拾わない", arguments: [
        // **拾いすぎの実例**。語尾を「線」にしていたときは「右車線」が道路名になった。
        "右車線を走行して首都高速入口へ",
        "池尻ランプで右車線を走行 首都高速入口へ",
        // **切れた名前の実例**。ひらがなを名前に含めないので「大通り」だけが残る。
        // 名前の一部しか送れないくらいなら送らない。
        "みなとみらい大通りを直進",
        // 語尾だけで名前を持たないもの。
        "有料道路を通ります",
        "高速道路に入る",
        // そもそも道路名が出てこない指示文。**これが普通にある**ので、
        // 拾えないことは異常ではない。
        "突き当たりを右折します",
        "2番目の出口で出る",
        "ロータリーで2番目の出口",
        "Uターンします",
        "駐車を準備",
        "Arrive at your destination",
        "",
    ])
    func skipsInstructionsWithoutRoadName(instruction: String) {
        #expect(RoadName.first(in: instruction) == nil)
    }

    @Test("番号を持つ道は番号のまま返す（表記のゆれが無いほうを優先する）")
    func prefersNumberedRoads() {
        // 「国道156号」と「○○通り」が同じ文にあっても、番号のほうを返す。
        #expect(RoadName.first(in: "国道156号を右方向 玉川通り") == "国道156号")
    }
}
