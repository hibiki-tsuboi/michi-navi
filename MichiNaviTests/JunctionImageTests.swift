import CoreGraphics
import Testing

@testable import MichiNavi

/// 交差点の拡大図の当て込み。
///
/// **読めるかどうかは目でしか決まらない**（2026-08-23 に 5 通りを PNG に描いて確かめた）が、
/// **縮尺が潰れたこと**は数字で捕まえられる。潰れると出ていく道が数ポイントになり、
/// 矢じりだけの塊になる。実際に 2 度やった——入ってくる道を縮尺に混ぜたときと、
/// U ターンで基準を下に置いたままにしたとき。
@MainActor
struct JunctionImageTests {
    /// 出ていく道が画面上でこれだけの長さを持っていれば、線として読める。
    /// 潰れた実例はどちらも 20pt を割っていた。
    private let readableLength: CGFloat = 40

    private func drawnLength(_ departure: [CGPoint]) throws -> CGFloat {
        let transform = try #require(JunctionImage.fittingTransform(for: departure))
        let points = departure.map(transform)
        return zip(points, points.dropFirst())
            .reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    @Test("直角に曲がっても線として読める長さになる")
    func rightAngle() throws {
        #expect(try drawnLength([.zero, CGPoint(x: 50, y: 0), CGPoint(x: 100, y: 0)]) >= readableLength)
        #expect(try drawnLength([.zero, CGPoint(x: -50, y: 0), CGPoint(x: -100, y: 0)]) >= readableLength)
    }

    @Test("浅い分岐でも線として読める長さになる")
    func slightTurn() throws {
        #expect(try drawnLength([.zero, CGPoint(x: 25, y: 43), CGPoint(x: 50, y: 87)]) >= readableLength)
    }

    /// **ここが本題。** 出ていく道が下へ戻るので、基準を下に置いたままだと収める場所が
    /// 無くて縮尺が潰れる。
    @Test("折り返しでも線として読める長さになる")
    func hairpin() throws {
        #expect(try drawnLength([.zero, CGPoint(x: 20, y: -10), CGPoint(x: 10, y: -70)]) >= readableLength)
    }

    @Test("ほぼ直進でも線として読める長さになる")
    func nearlyStraight() throws {
        #expect(try drawnLength([.zero, CGPoint(x: 1, y: 50), CGPoint(x: 2, y: 100)]) >= readableLength)
    }

    /// **ごく短い区間を画面いっぱいに引き伸ばさない**（`minimumExtent`）。
    /// 枠に収める条件だけで倍率を決めると、5m の区間が道 1 本ぶんの太さと長さで描かれ、
    /// **実際より大きな交差点に見える**。下限を外すと 60pt まで伸びる。
    @Test("ごく短い区間を引き伸ばさない")
    func shortExitIsNotBlownUp() throws {
        #expect(try drawnLength([.zero, CGPoint(x: 0, y: 5)]) <= 20)
    }
}
