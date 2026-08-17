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
/// レベルと `privacy` の扱いは [CarPlayGestureLog] と同じ。走り終えてから吸い出せるよう
/// `.info` で出し、組み立て済みの文字列を渡すので `.public` を付けている。
/// **座標は載せない**（名前と種別だけ）。
enum CarPlayVehicleLog {
    /// 書き写さない理由は [CarPlayGestureLog] と同じ。
    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "MichiNavi",
                                   category: "vehicle")
    private static let logger = Logger(log)

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

    /// 曲がった先の道路名を指示文から拾えたか（`RoadName`）。
    ///
    /// **拾えなかった指示文も残す。** 見たいのは拾えた名前そのものではなく、**実路の
    /// 指示文でどれだけ落ちているか**なので、当たりだけ出すと分母が分からない。
    /// 落ちるのは異常ではない（道路名を持たない指示文がある）が、**落ちすぎか、
    /// 拾いすぎか**はここを読まないと決められない。元の文を並べているのは、
    /// 直すときに触るのが `RoadName` の語尾の表だから。
    ///
    /// 出るのは経路を組み立てるときだけで、step の数だけ並ぶ。
    static func roadName(_ name: String?, from instruction: String) {
        emit("road name=\(name ?? "—") ← \(instruction)")
    }

    /// ロータリーの出口の向きを車へ渡した。**基準の取り方（進行方向を 0 度、時計回りが正）は
    /// ヘッダに書かれておらず、こちらで決めたもの**なので、車がどう描いたかと突き合わせる
    /// ための記録が要る。出るのはロータリーのときだけ。
    static func roundabout(exitAngle degrees: Double) {
        emit("roundabout exitAngle=\(Int(degrees.rounded()))")
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

    private static func emit(_ message: @autoclosure () -> String) {
        guard log.isEnabled(type: .info) else { return }
        // 組み立てるのはここまで来たときだけ。`logger` の補間はエスケープする
        // `@autoclosure` なので、非エスケープの `message` をその中では呼べない。
        let text = message()
        logger.info("\(text, privacy: .public)")
    }
}
