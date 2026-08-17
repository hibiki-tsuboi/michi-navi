import Foundation

/// 到着予定が見込みからどれだけ遅れているか。CarPlay の到着予定を色分けするための材料。
///
/// **絶対的な混み具合ではない。** MapKit は道路ごとの交通量を返さないので、こちらから
/// 言えるのは「いま測り直した残り時間」と「経路を引いたときの見込みを残距離で按分した
/// 時間」の差だけ。つまり *出発時（引き直し時）の見込みに対して遅れているか* までで、
/// **出発した時点ですでに渋滞していた経路は `.flowing` になる**（その渋滞は見込みの側に
/// 入っているため）。Apple のマップが出す色とは意味が違うので、揃えようとしないこと。
///
/// 判定の材料は `NavigationController.refreshTravelTimeIfNeeded` が 3 分おきに測っている
/// ものをそのまま使う。**問い合わせは 1 本も足していない**（`TrafficAdvisor` と同じ枠）。
enum TrafficCondition {
    /// 見込みどおり進んでいる。
    case flowing
    /// 遅れている。
    case slow
    /// 大きく遅れている。
    case congested

    /// - Parameters:
    ///   - measured: いま測り直した残り時間。
    ///   - expected: 経路を引いたときの見込みを残距離で按分した時間。
    ///
    /// どちらかが 0 以下なら判定しない。案内の終わりぎわは残距離も残時間も 0 に近づき、
    /// 割合がいくらでも大きく出る。
    init?(measured: TimeInterval, expected: TimeInterval) {
        guard measured > 0, expected > 0 else { return nil }

        let delay = measured - expected
        if delay >= Self.congestedThreshold.delay, delay >= expected * Self.congestedThreshold.ratio {
            self = .congested
        } else if delay >= Self.slowThreshold.delay, delay >= expected * Self.slowThreshold.ratio {
            self = .slow
        } else {
            self = .flowing
        }
    }

    /// 遅れをどこから色に出すか。**割合と絶対値の両方を要求する。**
    ///
    /// 割合だけで見ると、残り 4 分の場面で 40 秒の遅れが「3 割」になって色が暴れる。
    /// 絶対値だけで見ると、長距離では按分の誤差だけで数分ぶんずれるので点いたままになる。
    /// 比べているのは実測と按分の見込みで、**後者には誤差がある**（step ごとの所要時間が
    /// 返らない）から、誤差と渋滞を取り違えない幅が要る——`TrafficAdvisor.minimumSaving`
    /// を 5 分に置いているのと同じ理由。
    private static let slowThreshold = (ratio: 0.15, delay: TimeInterval(180))
    private static let congestedThreshold = (ratio: 0.35, delay: TimeInterval(480))
}
