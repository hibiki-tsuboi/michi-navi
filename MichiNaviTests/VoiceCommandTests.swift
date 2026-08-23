import Testing
@testable import MichiNavi

/// 話した文を操作に読み解く（言語モデルを通さない側）。
///
/// **Apple Intelligence が無い環境ではこれが唯一走る経路**なので、
/// 判定を変えるときは誤爆の側を先に確かめること。取りこぼしても検索に落ちるだけだが、
/// 拾いすぎると**同乗者との会話で案内が切れる**。
struct VoiceCommandTests {
    // 型を明示しているのは、要素が増えると推論が音を上げて
    // 「cannot infer contextual base」で落ちるため。
    @Test("決まった言い回しだけを操作として拾う", arguments: [(String, VoiceCommand)]([
        ("案内を終了して", .endNavigation),
        ("ナビを終了", .endNavigation),
        ("もう一度言って", .repeatGuidance),
        ("全体を表示", .overview),
        ("stop navigation", .endNavigation),
        ("say that again", .repeatGuidance),
        ("show the whole route", .overview),
        ("家に帰りたい", .goHome),
        ("自宅", .goHome),
        ("帰宅する", .goHome),
        ("take me home", .goHome),
    ]))
    func recognizesCommands(text: String, expected: VoiceCommand) {
        #expect(VoiceCommand.fallback(from: text, isNavigating: true) == expected)
    }

    @Test("紛らわしい言葉では操作にしない（会話で案内を切らない）", arguments: [
        "終わり",
        "そろそろ終わりにしよう",
        "もういいや",
        "ぜんぶ見せて",
        // **「帰る」だけでは帰り道にしない。** 同乗者との会話で誤爆する。
        "そろそろ帰るね",
        "帰りは高速で",
    ])
    func doesNotFireOnConversation(text: String) {
        // 拾えなければ行き先として扱われる。**検索に落ちるだけなので害が小さい。**
        guard case .destination = VoiceCommand.fallback(from: text, isNavigating: true) else {
            Issue.record("「\(text)」が操作として拾われた")
            return
        }
    }

    @Test("それ以外は行き先として扱う")
    func treatsRestAsDestination() {
        #expect(VoiceCommand.fallback(from: "東京駅に行きたい", isNavigating: false)
            == .destination(query: "東京駅に行きたい", asWaypoint: false))
    }

    @Test("末尾の句読点は検索語から落とす")
    func trimsPunctuation() {
        #expect(VoiceCommand.fallback(from: "東京駅。", isNavigating: false)
            == .destination(query: "東京駅", asWaypoint: false))
    }

    @Test("案内中に「寄りたい」と言われたときだけ立ち寄り先にする")
    func waypointOnlyWhileNavigating() {
        #expect(VoiceCommand.fallback(from: "途中でコンビニに寄りたい", isNavigating: true)
            == .destination(query: "途中でコンビニに寄りたい", asWaypoint: true))
        // 案内していなければ、寄り道のしようがないので行き先そのもの。
        #expect(VoiceCommand.fallback(from: "途中でコンビニに寄りたい", isNavigating: false)
            == .destination(query: "途中でコンビニに寄りたい", asWaypoint: false))
    }
}
