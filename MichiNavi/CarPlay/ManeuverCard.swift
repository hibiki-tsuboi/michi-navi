import CarPlay
import UIKit

/// 同じ指示をセンター画面・Dashboard・通知・車のメーターへ渡す。
/// 属性付きの文だけが古い短縮形に戻る、といった表示先ごとの食い違いを防ぐ。
enum ManeuverCard {
    /// 高速の上で出すカードの地色。**日本の案内標識と同じ緑**（一般道は青の
    /// `CPMapTemplate.guidanceBackgroundColor`）。
    ///
    /// **`systemGreen` は使わない。** 明るすぎて白い文字が沈むうえ（白とのコントラスト比は
    /// 2.2:1。いまの青は 4.0:1、この緑は 6.6:1）、「成功」を知らせる色に見える。標識の緑は
    /// 暗く、白抜きで読ませるために選ばれている値なので、そちらへ寄せる。
    /// **固定の色にする。** 夜に明るくなる動的な色だと、標識と同じ色という理由が消える
    /// （走った道の灰色を `systemGray` にしないのと同じ）。**昼夜の地図に重ねて選んだ。**
    ///
    /// **`private` にしていないのはテストのため。** `CPManeuver.cardBackgroundColor` は
    /// 渡した色をそのまま返さず、`UIDynamicAppDefinedColor` に包んで持つ（CarPlay の外で
    /// 解決すると白になる）ので、**読み返して確かめられない**。色を見るなら渡す側を見る。
    static let highwayColor = UIColor(red: 0x00 / 255, green: 0x6B / 255, blue: 0x3C / 255, alpha: 1)

    static func make(for instruction: ManeuverInstruction, onHighway: Bool = false) -> CPManeuver {
        let kind = ManeuverKind(instruction)
        let maneuver = CPManeuver()
        // 日本の案内標識は高速が緑、一般道が青。`cardBackgroundColor` は
        // `guidanceBackgroundColor` より優先されるので、指示ごとに切り替えられる
        // （センター・Dashboard・メーター内の 3 画面ともこの値を読む）。
        if onHighway { maneuver.cardBackgroundColor = highwayColor }
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
