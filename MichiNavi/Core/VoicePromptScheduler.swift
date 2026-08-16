import CoreLocation

/// 読み上げる案内 1 件。
enum VoicePrompt: Equatable {
    /// 案内開始直後の最初のひと言。
    case start(instruction: String)
    /// 経路を外れて引き直した直後のひと言。
    case rerouted(instruction: String)
    /// 「300メートル先、右折します」。`distance` が nil なら「まもなく」。
    case maneuver(instruction: String, distance: CLLocationDistance?)
    /// 経由地に着いたとき。案内は続くので、終了とは言い分ける。
    case waypoint(name: String)
    case arrival(destination: String)
    /// 連続運転が長くなったとき。案内とは無関係に流れる。
    case rest(hours: Int)

    var spokenText: String {
        switch self {
        case let .start(instruction):
            return String(localized: "案内を開始します。\(instruction)")
        case let .rerouted(instruction):
            return String(localized: "ルートを再検索しました。\(instruction)")
        case let .maneuver(instruction, distance):
            guard let distance else { return String(localized: "まもなく\(instruction)") }
            return String(localized: "\(Formatters.spokenDistance(distance))先、\(instruction)")
        case let .waypoint(name):
            return String(localized: "経由地の\(name)に到着しました。案内を続けます")
        case let .arrival(destination):
            return String(localized: "\(destination)に到着しました。案内を終了します")
        case let .rest(hours):
            return String(localized: "運転を始めて\(hours)時間になります。そろそろ休憩しませんか")
        }
    }
}

/// どの地点で何を読み上げるかを決める。ルート 1 本につき 1 インスタンス。
///
/// `RouteProgress` は位置更新のたびに届くので、そのまま読み上げると同じ指示を
/// 何度も繰り返す。step ごとに「どのしきい値まで読んだか」を記録して 1 回に抑える。
final class VoicePromptScheduler {
    /// 手前から予告する距離。長い区間ほど早い段階から知らせる。
    private let thresholds: [CLLocationDistance] = [1000, 500, 200]
    /// 曲がる直前の「まもなく」。読み直し（`VoiceGuidance.repeatCurrentGuidance`）も
    /// 同じ値で言い分けるので `static`。
    static let imminentThreshold: CLLocationDistance = 60
    /// 区間がしきい値に対して十分長いときだけ予告する。
    /// 300m しかない区間で「1キロ先を右折」と言わせないための比率。
    private let minimumStepRatio: Double = 1.4

    /// リルート直後は「案内を開始します」ではなく「再検索しました」で始める。
    private let isReroute: Bool

    private var announced: Set<Announcement> = []
    private var hasOpened = false

    private struct Announcement: Hashable {
        let stepIndex: Int
        let threshold: CLLocationDistance
    }

    init(isReroute: Bool = false) {
        self.isReroute = isReroute
    }

    func prompt(for progress: RouteProgress, on route: NavRoute) -> VoicePrompt? {
        guard route.steps.indices.contains(progress.stepIndex) else { return nil }

        let step = route.steps[progress.stepIndex]
        let remaining = progress.distanceToNextManeuver

        if !hasOpened {
            hasOpened = true
            // 開始位置がすでに交差点の手前だった場合に、通り過ぎた予告を
            // 後から読まないよう済みにしておく。
            markPassed(stepIndex: progress.stepIndex, from: remaining)
            return isReroute ? .rerouted(instruction: step.instruction)
                             : .start(instruction: step.instruction)
        }

        if remaining <= Self.imminentThreshold {
            guard claim(stepIndex: progress.stepIndex, threshold: Self.imminentThreshold) else { return nil }
            return .maneuver(instruction: step.instruction, distance: nil)
        }

        // いま踏み越えたしきい値のうち、いちばん小さいものだけを読む。
        // トンネル明けなどで一気に近づいたときに「1キロ先」から読み直さないため。
        let due = thresholds
            .filter { remaining <= $0 && step.distance >= $0 * minimumStepRatio }
            .min()

        guard let due, claim(stepIndex: progress.stepIndex, threshold: due) else { return nil }
        markPassed(stepIndex: progress.stepIndex, from: due)
        return .maneuver(instruction: step.instruction, distance: due)
    }

    /// 指定距離以上のしきい値をまとめて読み上げ済みにする。
    private func markPassed(stepIndex: Int, from distance: CLLocationDistance) {
        for threshold in thresholds where threshold >= distance {
            announced.insert(Announcement(stepIndex: stepIndex, threshold: threshold))
        }
    }

    /// まだ読んでいなければ記録して true を返す。
    private func claim(stepIndex: Int, threshold: CLLocationDistance) -> Bool {
        announced.insert(Announcement(stepIndex: stepIndex, threshold: threshold)).inserted
    }
}
