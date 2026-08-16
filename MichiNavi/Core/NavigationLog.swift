import CoreLocation
import Foundation
import os

/// 経路を外れた・引き直したという判断だけを残すログ。
///
/// 設けている理由は [CarPlayGestureLog] と同じで、**画面を見ても何が起きたか分からない**ため。
/// 引き直しの結果は「案内カードが一瞬入れ替わる」という形でしか出てこないので、
/// 次の 3 つが同じ見え方になる。
///
///   - `GuidanceEngine` が逸脱と判断した
///   - 判断したが、間隔や停車を理由に見送った
///   - 投げたが失敗した
///
/// どれなのかが分かれば、しきい値（50m・3 回連続・`stoppedSpeed`）のどれを疑えばよいかも決まる。
///
/// **`.info` で出す**。`.debug` は誰かが受け取っているあいだしか捕まらず、Mac を繋がずに
/// 走ったあとで吸い出せない。この記録が要るのはまさにその場面。
enum NavigationLog {
    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "MichiNavi",
                                   category: "route")
    private static let logger = Logger(log)

    /// 案内を始めた。引き直しの行がこの直後に並んだら、開始地点の側を疑う。
    static func navigationStarted(steps: Int, distance: CLLocationDistance) {
        emit("start steps=\(steps) distance=\(Int(distance))m")
    }

    /// 逸脱が成立して引き直しの判断まで来た。
    ///
    /// **数字を 3 つとも載せる**。中心線からの距離は逸脱そのもの、測位の精度は
    /// 「その距離を信じてよいか」、速度は停車の判定に効く。どれが効いたのかは
    /// 揃っていないと読めない。
    static func offRoute(distanceFromRoute: CLLocationDistance,
                         accuracy: CLLocationAccuracy,
                         speed: CLLocationSpeed) {
        emit("off-route fromRoute=\(Int(distanceFromRoute))m accuracy=\(Int(accuracy))m "
            + "speed=\(String(format: "%.1f", speed))m/s")
    }

    /// 引き直しを見送った。`reason` は `stopped` / `interval` / `calculating`。
    static func rerouteSkipped(_ reason: String) {
        emit("reroute skipped(\(reason))")
    }

    static func rerouteStarted() {
        emit("reroute started")
    }

    /// 引き直しの結果。`changed` が false なら、引き直したのに前と同じ経路が返っている
    /// （＝引き直す意味が無かった）。
    static func rerouteFinished(succeeded: Bool, changed: Bool) {
        emit("reroute \(succeeded ? "succeeded" : "failed") changed=\(changed)")
    }

    // MARK: -

    private static func emit(_ message: @autoclosure () -> String) {
        guard log.isEnabled(type: .info) else { return }
        // 組み立てるのはここまで来たときだけ。`logger` の補間はエスケープする
        // `@autoclosure` なので、非エスケープの `message` をその中では呼べない。
        let text = message()
        logger.info("\(text, privacy: .public)")
    }
}
