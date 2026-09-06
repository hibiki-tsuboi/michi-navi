import Foundation
import Testing
@testable import MichiNavi

@MainActor
struct ManeuverInstructionTests {
    @Test("方面の複数の地名を欠かさず強調する", arguments: [
        ("竹橋JCTで左車線を走行して首都高速都心環状線（霞が関、中央道方面）へ", "霞が関、中央道"),
        ("谷町JCTで右車線を走行して渋谷、東名方面へ", "渋谷、東名"),
        ("生麦JCTで右車線を走行して首都高速神奈川1号横羽線（羽田、生麦出口方面）へ", "羽田、生麦出口"),
        ("渋谷ランプで出口（玉川通り、山手通り方面）", "玉川通り、山手通り"),
        ("谷田部ICで出口（つくば、354方面）", "つくば、354"),
        ("竹橋JCTで左車線を走行して首都高速（霞が関、 中央道方面）へ", "霞が関、 中央道"),
        ("谷町JCTで右車線を走行して渋谷、 東名方面へ", "渋谷、 東名"),
        ("Take exit 23B on the left toward Shibuya / Shinjuku", "Shibuya / Shinjuku"),
    ])
    func destinationNames(instruction: String, expected: String) {
        #expect(ManeuverInstruction(instruction).signpost?.title == expected)
    }

    @Test("方面がなくても実際に書かれたIC名・出口番号を残す")
    func usesExitIdentityWhenDestinationIsAbsent() {
        let japanese = ManeuverInstruction("荻窪ICで出口")
        #expect(japanese.signpost?.title == "荻窪IC")
        #expect(japanese.exitLabel == "荻窪IC")
        let english = ManeuverInstruction("Take exit 23B on the left")
        #expect(english.signpost?.title == "exit 23B")
        #expect(english.exitLabel == "exit 23B")
        #expect(ManeuverInstruction("竹橋JCTで左車線を走行").exitLabel == nil)
    }

    @Test("狭い表示用の全候補でもJCT名・方向・方面を落とさない")
    func retainsSignpostInEveryVariant() {
        let original = "谷町ジャンクションで右車線を走行して渋谷、東名方面へ"
        let instruction = ManeuverInstruction(original)
        #expect(instruction.variants.first == original)
        #expect(instruction.compactVariants.first == "谷町JCTで右車線 渋谷、東名方面へ")
        for variant in instruction.variants + instruction.compactVariants {
            #expect(variant.contains("谷町"))
            #expect(variant.contains("右車線"))
            #expect(variant.contains("渋谷、東名方面"))
        }
    }

    @Test("短縮できない出口も『出口』だけに置き換えない")
    func retainsExitNameAndNumber() {
        for text in ["荻窪ICで出口（荻窪、小田原市街方面）", "Take exit 23B on the left toward Tokyo"] {
            let instruction = ManeuverInstruction(text)
            #expect(instruction.variants == [text])
            #expect(instruction.compactVariants == [text])
        }
    }

    @Test("読み取れない方面は地名を作らず全文で案内する")
    func doesNotInventSignpost() {
        #expect(ManeuverInstruction("この先を進んで東京方面へ").signpost == nil)
        #expect(ManeuverInstruction("出口へ").signpost == nil)
        #expect(ManeuverInstruction("出口へ").exitLabel == nil)
        #expect(ManeuverInstruction("Continue on the freeway").signpost == nil)
        // 複合指示を地名として出さず、読めた出口番号へ戻る。
        #expect(ManeuverInstruction("Take exit 23 toward Tokyo, then turn right").signpost?.title == "exit 23")
    }

    @Test("通常の右左折には短い候補を残す")
    func ordinaryTurnStillHasShortVariant() {
        let instruction = ManeuverInstruction("交差点を左折します")
        #expect(instruction.variants == ["交差点を左折します", String(localized: "左折")])
        #expect(instruction.compactVariants.first == String(localized: "左折"))
    }
}
