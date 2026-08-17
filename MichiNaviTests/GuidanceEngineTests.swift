import CoreLocation
import Testing
@testable import MichiNavi

/// 経路上の進捗計算。
///
/// ここで守っているのは**しきい値そのものではなく、しきい値の効かせ方**。
/// 「3 回連続で外れたときだけ」「精度が悪い測位は数えない」「経路に乗るまでは数えない」は
/// どれも実車で症状が出てから足された条件で、外すと**走行中にしか気づけない壊れ方**をする。
@MainActor
struct GuidanceEngineTests {
    /// 0m の出発 step ＋ 500m ＋ 500m。先頭を 0m にしてあるのは MapKit の実データが
    /// そうなっているため（`steps[0]` は距離 0・指示文なし）。
    private func makeEngine() -> (GuidanceEngine, NavRoute) {
        let route = SyntheticRoute.straight([("", 0), ("右方向", 500), ("目的地に到着", 500)])
        return (GuidanceEngine(route: route), route)
    }

    // MARK: - 区間の進み方

    @Test("0m の出発 step は飛ばす（空の指示をカードに出さないため）")
    func skipsZeroLengthFirstStep() {
        let (engine, _) = makeEngine()
        let progress = engine.update(with: SyntheticRoute.fix(at: SyntheticRoute.origin))
        #expect(progress.stepIndex == 1)
    }

    @Test("区間の終わりを越えたら次の step へ進む")
    func advancesStepAtBoundary() {
        let (engine, _) = makeEngine()
        _ = engine.update(with: SyntheticRoute.fix(at: SyntheticRoute.coordinate(north: 400)))
        #expect(engine.update(with: SyntheticRoute.fix(at: SyntheticRoute.coordinate(north: 490))).stepIndex == 1)
        #expect(engine.update(with: SyntheticRoute.fix(at: SyntheticRoute.coordinate(north: 520))).stepIndex == 2)
    }

    @Test("次の曲がり角までの距離は区間の終わりまで")
    func measuresDistanceToNextManeuver() {
        let (engine, _) = makeEngine()
        let progress = engine.update(with: SyntheticRoute.fix(at: SyntheticRoute.coordinate(north: 300)))
        #expect(abs(progress.distanceToNextManeuver - 200) < 5)
        #expect(abs(progress.distanceRemaining - 700) < 5)
    }

    // MARK: - 逸脱

    @Test("逸脱は 3 回連続で外れたときだけ確定する（GPS の跳ねで引き直さない）")
    func requiresThreeConsecutiveOffRouteFixes() {
        let (engine, _) = makeEngine()
        // まず経路に乗せる。乗るまでは数えない作りなので、ここを省くと何も起きない。
        _ = engine.update(with: SyntheticRoute.fix(at: SyntheticRoute.coordinate(north: 100)))

        let away = SyntheticRoute.coordinate(north: 100, east: 200)
        #expect(engine.update(with: SyntheticRoute.fix(at: away)).isOffRoute == false)
        #expect(engine.update(with: SyntheticRoute.fix(at: away)).isOffRoute == false)
        #expect(engine.update(with: SyntheticRoute.fix(at: away)).isOffRoute)
    }

    @Test("1 回でも経路に戻れば数え直す")
    func resetsStreakOnReturn() {
        let (engine, _) = makeEngine()
        _ = engine.update(with: SyntheticRoute.fix(at: SyntheticRoute.coordinate(north: 100)))

        let away = SyntheticRoute.coordinate(north: 100, east: 200)
        _ = engine.update(with: SyntheticRoute.fix(at: away))
        _ = engine.update(with: SyntheticRoute.fix(at: away))
        // 戻り。ここで数え直しになるので、続けて 2 回外れても確定しない。
        _ = engine.update(with: SyntheticRoute.fix(at: SyntheticRoute.coordinate(north: 120)))
        _ = engine.update(with: SyntheticRoute.fix(at: away))
        #expect(engine.update(with: SyntheticRoute.fix(at: away)).isOffRoute == false)
    }

    @Test("精度がしきい値より悪い測位は逸脱に数えない")
    func ignoresInaccurateFixes() {
        let (engine, _) = makeEngine()
        _ = engine.update(with: SyntheticRoute.fix(at: SyntheticRoute.coordinate(north: 100)))

        // 誤差 100m の位置で「中心線から 50m 以上離れている」とは言い切れない。
        // ビルの谷間やトンネル前後がこれで、数えるとリルートが連発する。
        let away = SyntheticRoute.coordinate(north: 100, east: 200)
        for _ in 0 ..< 5 {
            #expect(engine.update(with: SyntheticRoute.fix(at: away, accuracy: 100)).isOffRoute == false)
        }
    }

    @Test("経路に一度も乗っていないうちは逸脱を数えない（駐車場から始めたとき）")
    func doesNotJudgeBeforeJoiningRoute() {
        let (engine, _) = makeEngine()

        // MapKit は経路の始点を最寄りの車道へ寄せるので、施設の中から案内を始めると
        // 動く前から中心線の外に居る。ここを数えると止まったまま引き直しが走り続ける。
        let parking = SyntheticRoute.coordinate(north: 0, east: 300)
        for _ in 0 ..< 5 {
            #expect(engine.update(with: SyntheticRoute.fix(at: parking, speed: 0)).isOffRoute == false)
        }
    }

    @Test("乗らないまま出発地から 100m 離れたら数え始める")
    func judgesAfterLeavingDeparturePoint() {
        let (engine, _) = makeEngine()
        let parking = SyntheticRoute.coordinate(north: 0, east: 300)
        _ = engine.update(with: SyntheticRoute.fix(at: parking, speed: 0))

        // 駐車場から経路とは別の道へ出た場合。ここを塞いだままだと**最後まで一度も
        // 引き直せない**ので、乗っていなくても数え始める。
        let away = SyntheticRoute.coordinate(north: 0, east: 500)
        _ = engine.update(with: SyntheticRoute.fix(at: away))
        _ = engine.update(with: SyntheticRoute.fix(at: away))
        #expect(engine.update(with: SyntheticRoute.fix(at: away)).isOffRoute)
    }

    // MARK: - 到着

    @Test("到着は残り 30m")
    func arrivesWithinThreshold() {
        let (engine, _) = makeEngine()
        #expect(engine.update(with: SyntheticRoute.fix(at: SyntheticRoute.coordinate(north: 950))).hasArrived == false)
        #expect(engine.update(with: SyntheticRoute.fix(at: SyntheticRoute.coordinate(north: 985))).hasArrived)
    }

    // MARK: - 測位が途切れているあいだ

    @Test("推測は最後の速度で経路上を進める")
    func extrapolatesAlongRoute() {
        let (engine, _) = makeEngine()
        let measured = engine.update(with: SyntheticRoute.fix(at: SyntheticRoute.coordinate(north: 100), speed: 20))

        let guessed = try? #require(engine.extrapolate(elapsed: 5))
        // 20 m/s で 5 秒＝100m 進んだぶんだけ残りが減る。
        #expect(abs((measured.distanceRemaining - (guessed?.distanceRemaining ?? 0)) - 100) < 5)
    }

    @Test("推測では到着も逸脱も判定しない（トンネルの中で案内を終わらせない）")
    func extrapolationNeverArrivesOrLeavesRoute() {
        let (engine, _) = makeEngine()
        _ = engine.update(with: SyntheticRoute.fix(at: SyntheticRoute.coordinate(north: 900), speed: 20))

        // 経路の終わりを通り越すだけ進めても、着いたことにはしない。
        let guessed = engine.extrapolate(elapsed: 60)
        #expect(guessed?.hasArrived == false)
        #expect(guessed?.isOffRoute == false)
    }

    @Test("速度が取れていなければ推測しない")
    func doesNotExtrapolateWithoutSpeed() {
        let route = SyntheticRoute.straight([("", 0), ("右方向", 500)], expectedTravelTime: 0)
        let engine = GuidanceEngine(route: route)
        // 速度が負＝取れなかった測位。経路全体の平均速度も 0 なので進みようがない。
        _ = engine.update(with: SyntheticRoute.fix(at: SyntheticRoute.origin, speed: -1))
        #expect(engine.extrapolate(elapsed: 10) == nil)
    }

    // MARK: - 残り時間

    @Test("測り直した残り時間が以降の基準になる")
    func rebasesTimeRemainingOnMeasurement() {
        let (engine, _) = makeEngine()
        _ = engine.update(with: SyntheticRoute.fix(at: SyntheticRoute.coordinate(north: 500)))

        // 残り 500m の地点で「あと 1000 秒」と測り直したら、以降はそこからの距離比で減る。
        engine.applyMeasuredTimeRemaining(1_000)
        let progress = engine.update(with: SyntheticRoute.fix(at: SyntheticRoute.coordinate(north: 750)))
        #expect(abs(progress.timeRemaining - 500) < 20)
    }
}
