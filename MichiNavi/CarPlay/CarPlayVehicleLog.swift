import CarPlay
import Foundation
import os

/// 車との受け渡しだけを残すログ。
///
/// 設けている理由はジェスチャのログ（[CarPlayGestureLog]）と同じで、**画面を見ていても
/// 起きたかどうか分からない**ため。ルート共有も目的地共有も、こちらの画面は何も変わらず、
/// 結果が出るのは車の側（メーター・HUD・純正ナビ）。対応していない車では何も起きないのが
/// 正常なので、「届いていない」と「そもそも呼ばれていない」を分けられないと切り分けに困る。
///
/// CarPlay Simulator の "Route Sharing" / "Destination Information" と突き合わせて読む。
///
/// `.debug` なので既定では保存されず、Xcode を繋いでいるときだけ流れる。
/// `privacy: .public` を付けているのは、既定だと中身が `<private>` に伏せられるため。
/// **座標は載せない**（名前と種別だけ）。
enum CarPlayVehicleLog {
    private static let logger = Logger(subsystem: "jp.hibiki.michinavi", category: "vehicle")

    /// 車が経路をどう扱っているか。`vehicle` は車の側が経路を持ち替えたことを表す。
    @available(iOS 26.4, *)
    static func routeSource(_ source: CPRouteSource) {
        emit("routeSource=\(name(of: source))")
    }

    /// 車から立ち寄り先の提案が来た。EV の充電が代表例。
    static func waypointProposed(name: String) {
        emit("waypoint proposed name=\(name)")
    }

    /// 提案の所要を返した／返せなかった。返さないと既定の確認カードは出ない。
    static func waypointEstimated(succeeded: Bool) {
        emit("waypoint estimate \(succeeded ? "sent" : "failed")")
    }

    static func waypointDecided(accepted: Bool) {
        emit("waypoint \(accepted ? "accepted" : "declined")")
    }

    /// 案内していないときに、車から目的地そのものが送られてきた。
    static func destinationRequested(name: String) {
        emit("destination requested name=\(name)")
    }

    /// 目的地を車の純正ナビへ渡した結果。
    static func destinationShared(succeeded: Bool) {
        emit("destination shared \(succeeded ? "ok" : "failed")")
    }

    // MARK: -

    @available(iOS 26.4, *)
    private static func name(of source: CPRouteSource) -> String {
        switch source {
        case .sourceInactive: "inactive"
        case .sourceiOSUnchanged: "iOSUnchanged"
        case .sourceiOSRouteModified: "iOSRouteModified"
        case .sourceiOSRouteDestinationsModified: "iOSRouteDestinationsModified"
        case .sourceiOSDestinationsOnly: "iOSDestinationsOnly"
        case .sourceVehicle: "vehicle"
        @unknown default: "unknown(\(source.rawValue))"
        }
    }

    private static func emit(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }
}
