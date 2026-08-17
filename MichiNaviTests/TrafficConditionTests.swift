import Testing
@testable import MichiNavi

/// 到着予定の色の元になる見立て。
///
/// **しきい値は割合と絶対値の両方を要求する**という形そのものを守る。片方だけにすると、
/// 目的地の手前で色が暴れる（割合だけ）か、長距離で点きっぱなしになる（絶対値だけ）。
struct TrafficConditionTests {
    @Test("見込みどおりなら flowing")
    func onTimeIsFlowing() {
        #expect(TrafficCondition(measured: 600, expected: 600) == .flowing)
        // 早く着くぶんには何も言わない。
        #expect(TrafficCondition(measured: 400, expected: 600) == .flowing)
    }

    @Test("割合が届いても、遅れが小さいうちは色を出さない")
    func smallDelayStaysFlowing() {
        // 残り 4 分に対する 40 秒（17%）。割合だけで見ると「遅れ」になるが、
        // 按分の誤差と区別が付かない幅なので出さない。
        #expect(TrafficCondition(measured: 280, expected: 240) == .flowing)
    }

    @Test("遅れが絶対値でも割合でも届いたら slow")
    func realDelayIsSlow() {
        // 20 分の見込みに対して 5 分の遅れ（25%）。
        #expect(TrafficCondition(measured: 1_500, expected: 1_200) == .slow)
    }

    @Test("長距離では割合が効いて、絶対値だけでは点かない")
    func longTripNeedsRatioToo() {
        // 2 時間の見込みに対して 5 分（7%）の遅れ。按分の誤差でこれくらいは動く。
        #expect(TrafficCondition(measured: 7_500, expected: 7_200) == .flowing)
    }

    @Test("大きく遅れたら congested")
    func heavyDelayIsCongested() {
        // 20 分の見込みに対して 10 分の遅れ（50%）。
        #expect(TrafficCondition(measured: 1_800, expected: 1_200) == .congested)
    }

    @Test("材料が無ければ判定しない（案内の終わりぎわで割合が暴れるため）")
    func refusesToJudgeWithoutMaterial() {
        #expect(TrafficCondition(measured: 0, expected: 600) == nil)
        #expect(TrafficCondition(measured: 600, expected: 0) == nil)
    }
}
