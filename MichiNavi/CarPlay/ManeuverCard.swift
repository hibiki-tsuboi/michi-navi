import CarPlay
import UIKit

/// 同じ指示をセンター画面・Dashboard・通知・車のメーターへ渡す。
/// 属性付きの文だけが古い短縮形に戻る、といった表示先ごとの食い違いを防ぐ。
enum ManeuverCard {
    static func make(for instruction: ManeuverInstruction) -> CPManeuver {
        let kind = ManeuverKind(instruction)
        let maneuver = CPManeuver()
        maneuver.instructionVariants = instruction.variants
        maneuver.dashboardInstructionVariants = instruction.compactVariants
        maneuver.notificationInstructionVariants = instruction.compactVariants

        // 画像付きの文が通常の文より優先されるので、こちらも同じ候補を使う。
        if let first = attributedInstruction(for: instruction.original) {
            maneuver.attributedInstructionVariants = [first] + instruction.variants.dropFirst().map {
                attributedInstruction(for: $0) ?? NSAttributedString(string: $0)
            }
        }
        maneuver.symbolImage = kind.image
        maneuver.maneuverType = kind.type
        if let exitLabel = instruction.exitLabel { maneuver.highwayExitLabel = exitLabel }

        let road = RoadName.first(in: instruction.original)
        // **センターディスプレイの案内カードには渡さない**（2026-09-12）。あちらは
        // `CPSPrimaryManeuverView.fitJunctionViewToHeight` が NO で、渡した 140×100pt が
        // そのままカードの高さになる。カードの下端が到着予定トレイの上端に届くと、
        // CarPlay は `_checkNavigationCardHelperViewForETAFit` から `_setETAViewHidden:` を
        // 呼んで**トレイごと消す**（こちらから出し入れする API は無い）。道路名は指示文にも
        // `roadFollowingManeuverVariants` にも入っているので、**運転者がいちばん見る
        // 到着予定と引き換えにはしない**。Dashboard は同じメソッドが YES ＝画像を高さに
        // 合わせて縮めるので、あちらにだけ渡す。
        maneuver.dashboardJunctionImage = RoadNameImage.make(for: road, direction: instruction.direction,
                                                            signpost: instruction.signpost)
        if let road { maneuver.roadFollowingManeuverVariants = [road] }
        CarPlayVehicleLog.roadName(road, from: instruction.original)
        return maneuver
    }

    /// 道路番号を標識の画像に置き換える。CarPlayが受け付ける属性は画像の添付だけ。
    private static func attributedInstruction(for instruction: String) -> NSAttributedString? {
        guard let found = RoadNumber.first(in: instruction),
              let image = RoadShieldImage.make(for: found.road) else { return nil }

        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: -4, width: image.size.width, height: image.size.height)

        let result = NSMutableAttributedString(string: String(instruction[..<found.range.lowerBound]))
        result.append(NSAttributedString(attachment: attachment))
        result.append(NSAttributedString(string: String(instruction[found.range.upperBound...])))
        return result
    }
}
