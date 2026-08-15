import CarPlay
import Foundation
import os

/// タッチジェスチャの生の値だけを残すログ。
///
/// 設けているのは、**ジェスチャが届いていないのか、届いたうえで効き方がおかしいのかが、
/// 画面を見ているだけでは区別できない**ため。とくに 1 本指のパンは車の申告するタッチ精度に
/// よって認識器そのものが付かないことがあり（`didUpdatePanGestureWithTranslation` のヘッダに
/// ある "May not be called when connected to some CarPlay systems"）、そのときも
/// 「地図が動かない」というまったく同じ見え方になる。行が出るかどうかで切り分ける。
///
/// 入力と結果を 1 行に並べてあるのは、実車で確かめる 3 つ（回転の向き・傾きの重さ・
/// ピンチの追従性）がどれも「渡した値に対して出た結果」を見ないと判断できないため。
/// 値の意味は CarPlay ホストの逆アセンブルから推測したもので、**係数と符号は未確認**。
///
/// `.debug` なので、既定では保存されず Xcode を繋いでいるときだけ流れる。走行中の
/// オーバーヘッドを気にせず置いておける。`privacy: .public` を付けているのは、
/// 既定だと数値が `<private>` に伏せられて肝心の中身が読めないから。
/// **位置情報は載せない**（画面座標・角度・倍率だけ）。
enum CarPlayGestureLog {
    private static let logger = Logger(subsystem: "jp.hibiki.michinavi", category: "gesture")

    // MARK: パン

    /// 指でのドラッグ。`translation` は累積値ではなく前回からの差分。
    /// 等速でドラッグしているのに値が 0 付近まで落ちるなら、CarPlay 側が累積値を
    /// 送ってきていて、こちらの前提が外れている。
    static func drag(translation: CGPoint, velocity: CGPoint) {
        emit("drag translation=\(point(translation)) velocity=\(point(velocity))")
    }

    /// ノブ・トラックパッドでの方向入力。指のドラッグと区別するために分けてある。
    static func pan(direction: CPMapTemplate.PanDirection) {
        let names = [(CPMapTemplate.PanDirection.left, "left"), (.right, "right"),
                     (.up, "up"), (.down, "down")]
            .filter { direction.contains($0.0) }
            .map(\.1)
        emit("pan direction=\(names.isEmpty ? "none" : names.joined(separator: "|"))")
    }

    // MARK: ピンチ・タップ

    static func zoomBegan() {
        emit("zoom began")
    }

    /// `isTap` はダブルタップ・2 本指タップと判定したかどうか。取り違えると
    /// ピンチが 1 段ズームになる（またはタップが無反応になる）ので、必ず残す。
    static func zoom(center: CGPoint, scale: CGFloat, velocity: CGFloat, isTap: Bool, camera: String) {
        emit("zoom \(isTap ? "tap" : "pinch") center=\(point(center)) scale=\(number(scale)) velocity=\(number(velocity)) → \(camera)")
    }

    static func zoomEnded(velocity: CGFloat) {
        emit("zoom ended velocity=\(number(velocity))")
    }

    // MARK: 回転

    static func rotationBegan() {
        emit("rotation began")
    }

    static func rotation(center: CGPoint, radians: CGFloat, velocity: CGFloat, camera: String) {
        emit("rotation center=\(point(center)) radians=\(number(radians)) velocity=\(number(velocity)) → \(camera)")
    }

    static func rotationEnded(velocity: CGFloat) {
        emit("rotation ended velocity=\(number(velocity))")
    }

    // MARK: ピッチ

    static func pitchBegan() {
        emit("pitch began")
    }

    static func pitch(center: CGPoint, camera: String) {
        emit("pitch center=\(point(center)) → \(camera)")
    }

    static func pitchEnded(center: CGPoint) {
        emit("pitch ended center=\(point(center))")
    }

    // MARK: -

    private static func emit(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    private static func point(_ value: CGPoint) -> String {
        String(format: "(%.1f, %.1f)", value.x, value.y)
    }

    private static func number(_ value: CGFloat) -> String {
        String(format: "%.3f", value)
    }
}
