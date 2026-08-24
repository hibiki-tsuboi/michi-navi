import Foundation
import os

/// 県境・初めての街の読み上げが「出た／出なかった」の理由だけを残す。
///
/// 設けている理由は [ParkingLog] と同じで、**出なかったときに画面には何も出ない**ため。
/// しかもこれは**声だけの機能**なので、黙ったときの見え方は「何も起きていない」1 種類しか
/// ない。次の 6 つが全部それになる。
///
///   - `TrackStore.isRecording` が切り、または圏外で市区町村を引けていない
///   - まだ 3km 走っていない（`TrackStore.geocodeInterval`）
///   - 都道府県が変わっておらず、市区町村も初めてではない
///   - 初めての市区町村だが、前のひと言から間隔が空いていない
///   - 決まったが、曲がり角が近い・読み上げ中・聞き取り中で見送った
///   - 読もうとしたが `promptStyle` が `none` だった（通話中・Siri 中）
///
/// 上 2 つはここに `located` が出るかどうかで分かれる。**`located` が出ていれば土台は
/// 動いている**ので、疑うのは判定と声の側だけになる。
///
/// **`.info` で出す**。理由は [NavigationLog] と同じで、Mac を繋がずに走ったあとに
/// 吸い出せる必要があるため。
enum VisitLog {
    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "MichiNavi",
                                   category: "visit")
    private static let logger = Logger(log)

    /// 市区町村を引いた。**ここが出ないなら土台のほう**（記録が切り・圏外・3km 未満）。
    static func located(prefecture: String, city: String, isFirst: Bool) {
        emit("located \(prefecture)/\(city) first=\(isFirst)")
    }

    /// 言うことが決まった。
    static func noticed(_ notice: VisitAdvisor.Notice) {
        switch notice {
        case let .prefecture(name, firstCity):
            emit("notice prefecture=\(name) firstCity=\(firstCity ?? "—")")
        case let .firstCity(name):
            emit("notice firstCity=\(name)")
        }
    }

    /// 言うことが無かった。`reason` は `disabled` / `too-soon` / `same-ground`。
    static func skipped(_ reason: String) {
        emit("skipped(\(reason))")
    }

    /// 決まったのに読まなかった。`reason` は `suspended` / `speaking` / `maneuver-near`。
    /// **溜めずに捨てている**ので、ここに出たひと言は二度と来ない。
    static func silenced(_ reason: String) {
        emit("silenced(\(reason))")
    }

    // MARK: -

    private static func emit(_ message: @autoclosure () -> String) {
        guard log.isEnabled(type: .info) else { return }
        let text = message()
        logger.info("\(text, privacy: .public)")
    }
}
