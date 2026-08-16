import Combine
import Foundation

/// 走っている道より明らかに早い道が出てきたら知らせる。
///
/// **問い合わせは 1 本も足していない。** `NavigationController.refreshTravelTimeIfNeeded` が
/// 3 分おきに「いま引き直すとどうなるか」を計算していて、これまでその経路を捨てて
/// 所要時間だけ使っていた。判断の材料はもう揃っている。
///
/// ほかの助言の層と同じく、**こちらから経路は差し替えない**。走行中に経路が入れ替わると
/// 音声も案内カードも追随できないので、押されたときだけ切り替える。
@MainActor
final class TrafficAdvisor {
    static let shared = TrafficAdvisor()

    struct Advice {
        /// 切り替える先。すでに計算済みなので、押されたらそのまま渡せる。
        let route: NavRoute
        /// 切り替えると縮む時間。
        let saving: TimeInterval
    }

    /// 提案が決まった瞬間に流れる。
    let advice = PassthroughSubject<Advice, Never>()

    private let navigation = NavigationController.shared

    /// これだけ縮まないと出さない。
    ///
    /// **小さくしないこと。** 比べているのは「いま測った時間」と「距離按分で見込んで
    /// いた時間」で、後者には誤差がある（`GuidanceEngine` は step ごとの所要時間を
    /// 持てない）。測り直しが 3 分おきに基準を置き直すので誤差の溜まる幅はその範囲だが、
    /// それでも分単位で動く。**誤差と渋滞を取り違えないだけの差**を要求する。
    private static let minimumSaving: TimeInterval = 5 * 60

    /// 続けて出さない間隔。渋滞は数分では消えないので、3 分ごとの測り直しに合わせて
    /// 毎回出すと、迂回の提案ではなく催促になる。
    private static let minimumInterval: TimeInterval = 10 * 60

    private var lastAdvisedAt: Date?
    /// すでに勧めた道。**断られた道をもう一度勧めない。**
    private var advisedRoads = Set<[String]>()
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func start() {
        navigation.$phase
            .sink { [weak self] in self?.apply(phase: $0) }
            .store(in: &cancellables)

        navigation.travelTimeMeasured
            .sink { [weak self] in self?.evaluate($0) }
            .store(in: &cancellables)
    }

    /// 案内が終わったら忘れる。次の案内では同じ道でもまた勧めてよい。
    private func apply(phase: NavigationController.Phase) {
        if case .navigating = phase { return }
        lastAdvisedAt = nil
        advisedRoads.removeAll()
    }

    private func evaluate(_ measurement: NavigationController.TravelTimeMeasurement) {
        // **いま走っている区間の次から比べる。** 走行中の区間は引き直すと必ず短くなるので、
        // 同じ道でも先頭だけは食い違う。`signature` を使わないのも同じ理由（あちらは
        // 距離まで見る）。
        let mine = measurement.route.instructions(from: measurement.stepIndex + 1)
        let theirs = measurement.candidate.instructions(from: 1)
        // 同じ道が返ってきただけなら、切り替える先が無い。
        guard mine != theirs, !theirs.isEmpty else { return }
        guard !advisedRoads.contains(theirs) else { return }

        if let lastAdvisedAt, Date().timeIntervalSince(lastAdvisedAt) < Self.minimumInterval { return }

        let saving = measurement.projectedTimeRemaining - measurement.candidate.expectedTravelTime
        guard saving >= Self.minimumSaving else { return }

        lastAdvisedAt = Date()
        advisedRoads.insert(theirs)
        advice.send(Advice(route: measurement.candidate, saving: saving))
    }
}
