import Combine
import Foundation

/// 連続運転の時間を数えて、長くなったら休憩を促す。
///
/// 数えるのは**案内している時間**だけ。位置や速度から「走っているか」を判定する手もあるが、
/// 渋滞と停車が区別できず、案内を切って寄り道した時間も運転として数えてしまう。
/// 案内の開始と終了は利用者がはっきり示した区切りなので、そちらに乗る。
///
/// 案内が途切れて 15 分以上経っていたら、休んだものとして数え直す。
/// アプリを終了させると数えはじめに戻る（保存していない）。長距離の途中で
/// 落とすことは滅多になく、外したときに「休んだのに催促される」ほうが害が大きい。
@MainActor
final class RestReminder {
    static let shared = RestReminder()

    /// 連続運転がこれを超えたら 1 度だけ知らせる。
    /// 2 時間は高速道路の休憩間隔としてよく使われる目安。
    private static let drivingLimit: TimeInterval = 2 * 60 * 60
    /// 案内が途切れてこれだけ経っていたら休憩とみなす。
    private static let restThreshold: TimeInterval = 15 * 60

    /// しきい値を越えた瞬間に 1 回だけ流れる。
    let suggestion = PassthroughSubject<Void, Never>()

    private let navigation = NavigationController.shared

    /// いまの案内を始めた時刻。案内していなければ nil。
    private var drivingSince: Date?
    /// 前の案内までに積み上がった運転時間。
    private var accumulated: TimeInterval = 0
    /// 案内が終わった時刻。休憩とみなすかの判定に使う。
    private var stoppedAt: Date?
    private var hasSuggested = false
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func start() {
        navigation.$phase
            .sink { [weak self] in self?.apply(phase: $0) }
            .store(in: &cancellables)

        // 位置更新のたびに来る。時計を見るだけなので軽い。
        navigation.$progress
            .compactMap { $0 }
            .sink { [weak self] _ in self?.checkLimit() }
            .store(in: &cancellables)
    }

    private func apply(phase: NavigationController.Phase) {
        guard case .navigating = phase else {
            guard let drivingSince else { return }
            accumulated += Date().timeIntervalSince(drivingSince)
            self.drivingSince = nil
            stoppedAt = Date()
            return
        }

        // すでに走っている（リルートで経路が入れ替わっただけ）なら数え直さない。
        guard drivingSince == nil else { return }

        if let stoppedAt, Date().timeIntervalSince(stoppedAt) >= Self.restThreshold {
            accumulated = 0
            hasSuggested = false
        }
        drivingSince = Date()
    }

    private func checkLimit() {
        guard !hasSuggested, let drivingSince else { return }
        let total = accumulated + Date().timeIntervalSince(drivingSince)
        guard total >= Self.drivingLimit else { return }

        hasSuggested = true
        suggestion.send()
    }
}
