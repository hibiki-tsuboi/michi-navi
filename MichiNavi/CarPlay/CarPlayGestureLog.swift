import CarPlay
import Foundation
import os

/// タッチジェスチャの生の値と、それをカメラへ反映できたかどうかを残すログ。
///
/// 設けているのは、**ジェスチャが届いていないのか、届いたが受け付けていないのか、
/// 受け付けたうえで効き方がおかしいのかが、画面を見ているだけでは区別できない**ため。
/// とくに 1 本指のパンは車の申告するタッチ精度によって認識器そのものが付かないことがあり
/// （`didUpdatePanGestureWithTranslation` のヘッダにある "May not be called when connected to
/// some CarPlay systems"）、そのときも「地図が動かない」というまったく同じ見え方になる。
///
/// 入力と結果を 1 行に並べてあるのは、実車で確かめる 3 つ（回転の向き・傾きの重さ・
/// ピンチの追従性）がどれも「渡した値に対して出た結果」を見ないと判断できないため。
/// 値の意味は CarPlay ホストの逆アセンブルから推測したもので、**係数と符号は未確認**。
///
/// **行が 1 つも出ないことを「車の側の問題」と読まないこと。** こちら側にも同じ見え方に
/// なる原因がある（任意メソッドの名前違い・述語の subsystem 違い・捕捉レベル）。
/// 切り分けの順序は CLAUDE.md の「タッチジェスチャの手触り」に書いてある。
///
/// `.info` なのは、**この記録が要るのは Mac を繋げない実車の中**だから。`.debug` は
/// 誰かが受け取っているあいだしか捕まらず、走り終えてから `log collect` しても何も残らない。
/// `.info` はメモリバッファに載るので、走ったあとで端末から吸い出せる。走行中の負担は
/// 指が地図に触れているあいだだけで、[emit] が出力を組み立てるのも捕捉が有効なときに限られる。
///
/// **位置情報は載せない**（画面座標・角度・倍率・移動量だけ）。方位を絶対値で出さないのは
/// それが `location.course` そのものだからで、理由は [CameraState.headingDelta] に書いてある。
enum CarPlayGestureLog {
    /// バンドル ID は `Bundle.main` から取る。書き写すと、ID を変えたり
    /// ターゲットを増やしたときに、**ログは出ているのに述語が拾わない**という
    /// 「ジェスチャが届かない」とまったく同じ見え方になる。
    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "MichiNavi",
                                   category: "gesture")
    private static let logger = Logger(log)

    // MARK: パン

    /// 指でのドラッグ。`translation` は累積値ではなく前回からの差分。
    /// 累積値を送ってきているなら、等速でドラッグしたときに値が単調に増えていく
    /// （差分なら一定のまま）。`moved` はそれを地図へ渡した結果、実際に動いた距離。
    static func drag(translation: CGPoint, velocity: CGPoint, moved: CLLocationDistance) {
        emit("drag translation=\(point(translation)) velocity=\(point(velocity)) moved=\(meters(moved))")
    }

    /// ノブ・トラックパッドでの方向入力（瞬間的に押したぶん）。指のドラッグと区別するために分けてある。
    static func pan(direction: CPMapTemplate.PanDirection, moved: CLLocationDistance) {
        emit("pan direction=\(names(of: direction)) moved=\(meters(moved))")
    }

    /// 押し続けたときの開始と終了。押しているあいだ CarPlay は何も送ってこないので、
    /// この 2 行のあいだに `pan` が並ぶかどうかで、自前の時計が回っているかを見る。
    static func panBegan(direction: CPMapTemplate.PanDirection) {
        emit("pan began direction=\(names(of: direction))")
    }

    static func panEnded(direction: CPMapTemplate.PanDirection) {
        emit("pan ended direction=\(names(of: direction))")
    }

    // MARK: ピンチ・タップ

    static func zoomBegan() {
        emit("zoom began")
    }

    /// `isTap` はダブルタップ・2 本指タップと判定したかどうか。取り違えると
    /// ピンチが 1 段ズームになる（またはタップが無反応になる）ので、必ず残す。
    static func zoom(center: CGPoint, scale: CGFloat, velocity: CGFloat, isTap: Bool,
                     outcome: GestureOutcome, camera: @autoclosure () -> CameraState) {
        emit("""
        zoom \(isTap ? "tap" : "pinch") center=\(point(center)) scale=\(number(scale)) \
        velocity=\(number(velocity)) \(outcome.rawValue) → \(text(camera()))
        """)
    }

    static func zoomEnded(velocity: CGFloat) {
        emit("zoom ended velocity=\(number(velocity))")
    }

    // MARK: 回転

    static func rotationBegan() {
        emit("rotation began")
    }

    static func rotation(center: CGPoint, radians: CGFloat, velocity: CGFloat,
                         outcome: GestureOutcome, camera: @autoclosure () -> CameraState) {
        emit("""
        rotation center=\(point(center)) radians=\(number(radians)) \
        velocity=\(number(velocity)) \(outcome.rawValue) → \(text(camera()))
        """)
    }

    static func rotationEnded(velocity: CGFloat) {
        emit("rotation ended velocity=\(number(velocity))")
    }

    // MARK: ピッチ

    static func pitchBegan() {
        emit("pitch began")
    }

    static func pitch(center: CGPoint, outcome: GestureOutcome, camera: @autoclosure () -> CameraState) {
        emit("pitch center=\(point(center)) \(outcome.rawValue) → \(text(camera()))")
    }

    static func pitchEnded(center: CGPoint) {
        emit("pitch ended center=\(point(center))")
    }

    // MARK: ジェスチャ以外

    /// ボタン・パン UI の出入り・`apply(phase:)` など、**指以外の理由で同じカメラが動いたとき**。
    /// これが無いと、2 行のジェスチャのあいだで方位や縮尺が飛んだ理由が分からず、
    /// とくに `recenter()` が進行中の回転・傾けの基準を捨てたことに気づけない。
    static func camera(_ reason: String, camera: @autoclosure () -> CameraState) {
        emit("camera \(reason) → \(text(camera()))")
    }

    // MARK: -

    /// 出力を組み立てるのは捕捉が有効なときだけ。`@autoclosure` にしてあるので、
    /// 呼び出し側の文字列補間も `camera()` もここを通るまで動かない。
    /// **`String` を作ってから `logger` へ渡すと、この判断より前に代金を払うことになる。**
    private static func emit(_ message: @autoclosure () -> String) {
        guard log.isEnabled(type: .info) else { return }
        // 組み立てるのはここまで来たときだけ（`logger` の補間はエスケープする
        // `@autoclosure` なので、非エスケープの `message` をその中では呼べない）。
        // 組み立て済みの文字列を渡すので `.public` が要る。`os.Logger` が既定で伏せるのは
        // 動的な文字列で、数値をそのまま補間するぶんには既定でも読める。
        let text = message()
        logger.info("\(text, privacy: .public)")
    }

    private static func text(_ camera: CameraState) -> String {
        String(format: "headingDelta=%+.1f pitch=%.1f%@ distance=%.0f%@ follow=%@",
               camera.headingDelta,
               camera.pitch, camera.pitchIsClamped ? "(clamped)" : "",
               camera.distance, camera.distanceIsClamped ? "(clamped)" : "",
               camera.isFollowingUser ? "on" : "off")
    }

    private static func names(of direction: CPMapTemplate.PanDirection) -> String {
        let names = [(CPMapTemplate.PanDirection.left, "left"), (.right, "right"),
                     (.up, "up"), (.down, "down")]
            .filter { direction.contains($0.0) }
            .map(\.1)
        return names.isEmpty ? "none" : names.joined(separator: "|")
    }

    private static func point(_ value: CGPoint) -> String {
        String(format: "(%.1f, %.1f)", value.x, value.y)
    }

    private static func number(_ value: CGFloat) -> String {
        String(format: "%.3f", value)
    }

    private static func meters(_ value: CLLocationDistance) -> String {
        String(format: "%.0fm", value)
    }
}
