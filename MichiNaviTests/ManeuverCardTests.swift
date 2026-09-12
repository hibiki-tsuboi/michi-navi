import CarPlay
import Testing
@testable import MichiNavi

@MainActor
struct ManeuverCardTests {
    @Test("出口の矢印と車へ渡す左右が一致し、不明なら向きを決めつけない", arguments: [
        ("左側の出口へ", "arrow.up.left", CPManeuverType.highwayOffRampLeft),
        ("右側の出口へ", "arrow.up.right", .highwayOffRampRight),
        ("渋谷ランプで出口（玉川通り、山手通り方面）", "road.lanes", .offRamp),
        ("左車線から右側の出口へ", "road.lanes", .offRamp),
        ("神田橋ランプで左方向 首都高速都心環状線入口へ", "arrow.up.left", .onRamp),
        ("生麦JCTで右車線を走行して首都高速神奈川1号横羽線（羽田、生麦出口方面）へ", "road.lanes.curved.right", .keepRight),
    ])
    func directionAgreesAcrossDisplays(text: String, symbol: String, type: CPManeuverType) {
        let instruction = ManeuverInstruction(text)
        let kind = ManeuverKind(instruction)
        let card = ManeuverCard.make(for: instruction)
        #expect(kind.symbolName == symbol)
        #expect(card.maneuverType == type)
        #expect(card.symbolImage != nil)
    }

    @Test("道路番号を画像にした候補・Dashboard・通知でもJCTと方面を残す")
    func everyDisplayRetainsSignpost() {
        let card = ManeuverCard.make(for: ManeuverInstruction(
            "竹橋JCTで左車線を走行して首都高速3号線（渋谷、東名方面）へ"))
        let variants = card.instructionVariants + card.dashboardInstructionVariants + card.notificationInstructionVariants
        #expect(!card.attributedInstructionVariants.isEmpty)
        for variant in variants + card.attributedInstructionVariants.map(\.string) {
            #expect(variant.contains("竹橋JCT"))
            #expect(variant.contains("左車線"))
            #expect(variant.contains("渋谷、東名方面"))
        }
        // **センターの案内カードには画像を渡さない。** 渡すとカードが伸びて、
        // CarPlay が下部の到着予定トレイを自動で消す（`ManeuverCard` の理由）。
        #expect(card.junctionImage == nil)
        #expect(card.dashboardJunctionImage != nil)
        // SDKでは非Optionalだが、出口でないmaneuverにはまだ値を設定していない。
        #expect((card.value(forKey: "highwayExitLabel") as? String ?? "").isEmpty)
    }

    @Test("出口番号は方面や道路番号と分けて車へ渡す")
    func exitNumberIsNotRoadNumber() {
        let exit = ManeuverCard.make(for: ManeuverInstruction("Take exit 23B on the left toward Route 246"))
        #expect(exit.highwayExitLabel == "exit 23B")
        let fork = ManeuverCard.make(for: ManeuverInstruction("Keep right toward Exit 12"))
        #expect((fork.value(forKey: "highwayExitLabel") as? String ?? "").isEmpty)
        #expect(fork.maneuverType == .keepRight)
    }
}
