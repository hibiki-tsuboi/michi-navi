import CoreLocation

/// 読み上げる案内 1 件。
enum VoicePrompt: Equatable {
    /// 案内開始直後の最初のひと言。
    case start(instruction: String)
    /// 経路を外れて引き直した直後のひと言。
    case rerouted(instruction: String)
    /// 立ち寄り先を挟んで引き直した直後のひと言。
    /// **引き直しと言い分ける。** 押した本人からすると勝手に再検索されたわけではない。
    case waypointAdded(instruction: String)
    /// 利用者が選んで別の道へ切り替えた直後のひと言。同上。
    case switched(instruction: String)
    /// 「300メートル先、右折します」。`distance` が nil なら「まもなく」。
    case maneuver(instruction: String, distance: CLLocationDistance?)
    /// 経由地に着いたとき。案内は続くので、終了とは言い分ける。
    case waypoint(name: String)
    /// 目的地に着いたとき。**「到着しました」と言い切らない。**
    /// 案内が終わるのは経路の終端の手前（`GuidanceEngine.arrivalThreshold`）で、
    /// その経路の終端もピンの手前にある（実測で 13〜640m）。**着く前に着いたと言う**
    /// ことになるので、一般のカーナビと同じく「周辺です」に留める。
    case arrival(destination: String)
    /// 連続運転が長くなったとき。案内とは無関係に流れる。
    case rest(hours: Int)
    /// 都道府県をまたいだとき。`firstCity` が入っていれば、その市区町村も初めて。
    /// **案内していないときにも流れる**（`VisitAdvisor`）。
    case prefecture(name: String, firstCity: String?)
    /// 初めて走る市区町村に入ったとき。同上。
    case firstCity(name: String)
    /// 到着したときの「収穫」（`TripSummary`）。**この走行で初めて通った土地だけを数える。**
    /// 初めてが 1 つも無ければそもそも作られないので、ここに 0 は来ない。
    case harvest(prefecture: String?, cities: Int, totalPrefectures: Int, totalCities: Int)

    var spokenText: String {
        switch self {
        case let .start(instruction):
            return String(localized: "案内を開始します。\(instruction)")
        case let .rerouted(instruction):
            return String(localized: "ルートを再検索しました。\(instruction)")
        case let .waypointAdded(instruction):
            return String(localized: "立ち寄り先を追加しました。\(instruction)")
        case let .switched(instruction):
            return String(localized: "新しいルートに切り替えました。\(instruction)")
        case let .maneuver(instruction, distance):
            guard let distance else { return String(localized: "まもなく\(instruction)") }
            return String(localized: "\(Formatters.spokenDistance(distance))先、\(instruction)")
        case let .waypoint(name):
            return String(localized: "経由地の\(name)に到着しました。案内を続けます")
        case let .arrival(destination):
            return String(localized: "\(destination)周辺です。案内を終了します")
        case let .rest(hours):
            return String(localized: "運転を始めて\(hours)時間になります。そろそろ休憩しませんか")
        case let .prefecture(name, firstCity):
            guard let firstCity else { return String(localized: "\(name)に入りました") }
            return String(localized: "\(name)に入りました。\(firstCity)を走るのは初めてです")
        case let .firstCity(name):
            // 「初めてです」ではなく「走るのは初めてです」。歩いて訪ねたことまでは
            // こちらに分からないので、言い切れるところで止める。
            return String(localized: "\(name)を走るのは初めてです")
        case let .harvest(prefecture, cities, totalPrefectures, totalCities):
            // **1 回につきひと言**（`VisitAdvisor.Notice` と同じ決めごと）。県と街の
            // 両方が初めてでも 2 つ並べない。県のほうを先に取るのは、数十キロに 1 回しか
            // 起きないぶん、聞いて嬉しいのがそちらだから。
            //
            // **通算を必ず添える。** これが無いと、走行中に `VisitAdvisor` が言ったことを
            // 到着時にもう一度言うだけになる。**貯まっていると分かるのはこの数字だけ。**
            if let prefecture {
                return String(localized: "\(prefecture)を走るのは初めてでした。通算\(totalPrefectures)都道府県です")
            }
            return String(localized: "初めての街を\(cities)か所通りました。通算\(totalCities)か所です")
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

    /// 最初のひと言をどう始めるか。**経路が入れ替わった理由で変わる。**
    /// 利用者が押して切り替えたのに「再検索しました」と言われると、押したことが
    /// 効いたのかどうかが分からない。
    private let opening: RouteChangeReason

    private var announced: Set<Announcement> = []
    private var hasOpened = false

    private struct Announcement: Hashable {
        let stepIndex: Int
        let threshold: CLLocationDistance
    }

    init(opening: RouteChangeReason = .started) {
        self.opening = opening
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
            switch opening {
            case .started: return .start(instruction: step.instruction)
            case .rerouted: return .rerouted(instruction: step.instruction)
            case .waypointAdded: return .waypointAdded(instruction: step.instruction)
            case .switched: return .switched(instruction: step.instruction)
            }
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
