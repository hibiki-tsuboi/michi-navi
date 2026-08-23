import CoreLocation
import MapKit
import Testing
@testable import MichiNavi

/// 経路を距離で切り出す計算。
///
/// 呼ぶのは 2 か所で、**どちらも切りすぎ・切らなすぎが画面に出ない**。
/// `RangeAdvisor` は届く範囲を切って補給先を探すので、長く切れば届かない場所を勧め、
/// 短く切れば手前ばかり勧める。`CarPlayMapViewController` は通ってきたところを塗るので、
/// ずれても「なんとなく合っている線」が出る。
@MainActor
struct RouteMeasurementTests {
    /// 10m 間隔で 1km。座標は北へまっすぐ並ぶ。
    private var route: NavRoute {
        SyntheticRoute.straight([("", 0), ("直進", 1_000)], spacing: 10)
    }

    /// `SyntheticRoute` が緯度 1 度＝111,319.49m として座標を作っているのと、
    /// `MKMapPoint` の距離がどれだけ合うか。**ここがずれると下の 3 つが全部ずれる。**
    ///
    /// **ぴたりとは合わない。** 111,319.49 は半径 6,378,137m の球の**赤道**での 1 度で、
    /// `MKMapPoint.distance` は緯度で補正を掛ける。2026-08-23 に測った実測値は
    /// 赤道 1000.004m、緯度 35 で 998.115m、緯度 60 で 997.152m——**緯度 35 で 0.19% 短い**。
    /// 1km につき 2m なので、しきい値を数十メートル単位で見ているテストには効かない。
    /// **合っていることではなく、ずれの大きさを止める**テストにしてある。
    @Test("メートルと座標の対応は MKMapPoint と 0.3% 以内で合う")
    func degreesMatchMapPoints() {
        let distance = MKMapPoint(SyntheticRoute.origin)
            .distance(to: MKMapPoint(SyntheticRoute.coordinate(north: 1_000)))
        #expect(abs(distance - 1_000) < 3)
    }

    /// **見るのは「超えないこと」と「1 間隔より手前で止まらないこと」。**
    /// ちょうどの点で切れるかどうか（`<=` か `<` か）は確かめない——上のずれのせいで
    /// 頼んだ距離に座標がぴたりと乗ることがなく、**境目を跨ぐ場面が作れない**。
    /// 呼び元が頼りにしているのもこの 2 つで、`RangeAdvisor` は超えると届かない
    /// 補給先を勧めることになる。
    @Test("頼んだ距離を超えない")
    func prefixStopsAtDistance() throws {
        let last = try #require(NavRoute.coordinates(route.coordinates, upTo: 250).last)
        let reached = MKMapPoint(SyntheticRoute.origin).distance(to: MKMapPoint(last))

        #expect(reached <= 250)
        #expect(reached > 250 - 10)
    }

    @Test("全長より長く頼んでも全部までしか返らない")
    func longerThanRouteReturnsWholeRoute() {
        #expect(NavRoute.coordinates(route.coordinates, upTo: 5_000).count == route.coordinates.count)
    }

    @Test("0m なら何も返らない")
    func zeroReturnsNothing() {
        #expect(NavRoute.coordinates(route.coordinates, upTo: 0).isEmpty)
    }
}
