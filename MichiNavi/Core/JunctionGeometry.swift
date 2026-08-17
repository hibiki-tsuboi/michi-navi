import CoreGraphics
import CoreLocation
import MapKit

/// 曲がる地点の前後だけを切り出した、**経路そのものの形**。
///
/// MapKit は交差点のデータを一切返さない（形も、通らない側の道も、車線も）。返ってくるのは
/// たどる線だけなので、曲がり方を知りたければその線から測るしかない。ここが出すのは
/// 測った結果だけで、**見せ方は持たない**。行き先が 2 つあるため:
///
///   1. 交差点の拡大図（`JunctionImage`）
///   2. `CPManeuver.junctionExitAngle`。**車のメーター・HUD へ送られる**
///
/// `ManeuverDirection`（`Core/`）と `ManeuverKind`（`CarPlay/`）を分けているのと同じ形。
/// 測る計算は案内の見た目とは無関係なので、そのために `Core/` へ CarPlay を持ち込まない。
///
/// **絵と角度は必ず同じ値から作ること。** 別々に測ると、案内カードの図と車の HUD が
/// 食い違って出る余地ができる。
///
/// 点の座標系は**メートル・進行方向が +y**。北上げのままだと、同じ右折でも走っている
/// 向きによって形が変わって見比べられないので、入ってくる向きを上に揃えてある。
struct JunctionGeometry {
    /// 曲がる地点へ入ってくる線。進行順（最後の点が曲がる地点）。
    let approach: [CGPoint]
    /// 曲がる地点から出ていく線。先頭が曲がる地点。
    let departure: [CGPoint]
    /// 出ていく向きが、入ってくる向きからどれだけ振れているか（ラジアン）。
    /// 0 が直進、正が右。
    let turn: CGFloat

    /// 曲がる地点の手前と先を、それぞれどれだけ入れるか。
    ///
    /// 広げるほど拡大図の縮尺が小さくなり、肝心の曲がり角が潰れる。**曲がる直前に見て
    /// 分かる範囲**に絞る。
    private static let approachDistance: CLLocationDistance = 100
    private static let departureDistance: CLLocationDistance = 100

    /// 向きを決めるために遡る／先を見る距離。直前の 1 点だけで決めると、交差点の中の
    /// 細かい点で向きが跳ねる。
    private static let headingSample: CLLocationDistance = 25

    /// `stepIndex` の区間の終わり（＝曲がる地点）の形。測れなければ nil。
    static func make(for route: NavRoute, stepIndex: Int) -> JunctionGeometry? {
        guard route.stepEndIndices.indices.contains(stepIndex) else { return nil }
        let junctionIndex = route.stepEndIndices[stepIndex]
        let coordinates = route.coordinates
        guard coordinates.indices.contains(junctionIndex) else { return nil }

        let junction = coordinates[junctionIndex]
        let metersPerPoint = MKMetersPerMapPointAtLatitude(junction.latitude)
        let origin = MKMapPoint(junction)

        // 曲がる地点を原点、北を +y としたメートル座標へ移す。
        // `MKMapPoint` の y は南へ向かって増えるので符号を返す。
        func local(_ coordinate: CLLocationCoordinate2D) -> CGPoint {
            let point = MKMapPoint(coordinate)
            return CGPoint(x: (point.x - origin.x) * metersPerPoint,
                           y: -(point.y - origin.y) * metersPerPoint)
        }

        let approach = trail(in: coordinates, from: junctionIndex, step: -1,
                            limit: approachDistance, map: local).reversed().map { $0 }
        let departure = trail(in: coordinates, from: junctionIndex, step: 1,
                              limit: departureDistance, map: local)
        guard approach.count >= 2, departure.count >= 2 else { return nil }

        guard let heading = heading(of: approach) else { return nil }
        let angle = atan2(heading.x, heading.y)
        let rotatedApproach = approach.map { rotate($0, by: angle) }
        let rotatedDeparture = departure.map { rotate($0, by: angle) }

        guard let turn = turnAngle(departure: rotatedDeparture) else { return nil }
        return JunctionGeometry(approach: rotatedApproach, departure: rotatedDeparture, turn: turn)
    }

    // MARK: - 座標の切り出し

    /// `from` から `step` 方向へ、累計 `limit` メートルぶんの点を集める。
    /// 先頭は必ず `from` 自身（＝曲がる地点）。
    private static func trail(in coordinates: [CLLocationCoordinate2D],
                              from index: Int,
                              step: Int,
                              limit: CLLocationDistance,
                              map: (CLLocationCoordinate2D) -> CGPoint) -> [CGPoint] {
        var points = [map(coordinates[index])]
        var travelled: Double = 0
        var current = index

        while true {
            let next = current + step
            guard coordinates.indices.contains(next) else { break }
            let point = map(coordinates[next])
            travelled += hypot(point.x - points[points.count - 1].x,
                               point.y - points[points.count - 1].y)
            points.append(point)
            current = next
            if travelled >= limit { break }
        }
        return points
    }

    /// 曲がる地点に入ってくる向き。`approach` は進行順（最後が曲がる地点）。
    private static func heading(of approach: [CGPoint]) -> CGPoint? {
        guard let junction = approach.last else { return nil }

        // 手前へ `headingSample` メートル遡った点を基準にする。
        var reference = approach[0]
        var travelled: Double = 0
        for index in stride(from: approach.count - 1, to: 0, by: -1) {
            travelled += hypot(approach[index].x - approach[index - 1].x,
                               approach[index].y - approach[index - 1].y)
            if travelled >= headingSample {
                reference = approach[index - 1]
                break
            }
        }

        let vector = CGPoint(x: junction.x - reference.x, y: junction.y - reference.y)
        guard hypot(vector.x, vector.y) > 0 else { return nil }
        return vector
    }

    /// 出ていく向きが、入ってくる向きからどれだけ振れているか（ラジアン）。
    ///
    /// **回したあとの座標で見る。** 入ってくる向きが +y に揃っているので、出ていく点の
    /// 角度がそのまま曲がる角になる。曲がった直後の 1 点ではなく `headingSample` メートル
    /// 先を見るのは、交差点の中の細かい点で向きが跳ねるため。
    private static func turnAngle(departure: [CGPoint]) -> CGFloat? {
        var travelled: Double = 0
        for index in 1 ..< departure.count {
            travelled += hypot(departure[index].x - departure[index - 1].x,
                               departure[index].y - departure[index - 1].y)
            guard travelled >= headingSample else { continue }
            return atan2(departure[index].x, departure[index].y)
        }
        // 出ていく側が短いまま終わる（＝すぐ次の指示が来る）場合は、末端で見る。
        guard let last = departure.last, hypot(last.x, last.y) > 0 else { return nil }
        return atan2(last.x, last.y)
    }

    /// 反時計回りに `angle` だけ回す。`angle = atan2(v.x, v.y)` を渡すと `v` が +y を向く。
    private static func rotate(_ point: CGPoint, by angle: CGFloat) -> CGPoint {
        CGPoint(x: point.x * cos(angle) - point.y * sin(angle),
                y: point.x * sin(angle) + point.y * cos(angle))
    }
}
