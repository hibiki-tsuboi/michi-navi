import CoreLocation
import Foundation
import os

/// 駐車場の提案が「出た／出なかった」の理由だけを残す。
///
/// 設けている理由は [NavigationLog] と同じで、**出なかったときに画面には何も出ない**ため。
/// 次の 5 つが全部「何も起きなかった」という同じ見え方になる。
///
///   - しきい値（残り 1km）にまだ届いていない、または近所すぎて数えていない
///   - 自宅・職場なので黙った
///   - 検索そのものが失敗した（圏外・MapKit のレート制限）
///   - 見つかったが、全部が駐輪場などで落ちた
///   - 見つかったが、歩いて戻れない距離だった
///
/// とくに 4 つ目は [ParkingName] の表を足すか緩めるかの判断に直結する。`searched` の
/// `dropped` が実際の走行で何割になるかは、机上で 14 地点を測った 5% とは別の数字。
///
/// **`.info` で出す**。理由は [NavigationLog] と同じで、Mac を繋がずに走ったあとに
/// 吸い出せる必要があるため。
enum ParkingLog {
    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "MichiNavi",
                                   category: "parking")
    private static let logger = Logger(log)

    /// しきい値を切って探しに行った。ここが出ないなら、まだ遠いか `hasBeenFar` が立っていない。
    static func triggered(remaining: CLLocationDistance) {
        emit("triggered remaining=\(Int(remaining))m")
    }

    /// 探すまでもなく黙った。`reason` は `pinned` / `destination-is-parking`。
    static func skipped(_ reason: String) {
        emit("skipped(\(reason))")
    }

    /// 検索の結果。`dropped` は [ParkingName] が落とした数（駐輪場・ロータリーなど）。
    /// **`found` が 0 と、検索の失敗は別物**なので分けて出す。
    static func searched(found: Int, dropped: Int) {
        emit("searched found=\(found) dropped=\(dropped)")
    }

    static func searchFailed() {
        emit("search failed")
    }

    /// 実際に出した 1 件。**名前まで残す**。駐輪場を出していないかは名前でしか分からない。
    static func advised(name: String, walking: CLLocationDistance) {
        emit("advised walk=\(Int(walking))m name=\(name)")
    }

    /// 見つかったが出さなかった。`reason` は `none-usable` / `too-far`。
    static func dropped(_ reason: String) {
        emit("dropped(\(reason))")
    }

    // MARK: -

    private static func emit(_ message: @autoclosure () -> String) {
        guard log.isEnabled(type: .info) else { return }
        let text = message()
        logger.info("\(text, privacy: .public)")
    }
}
