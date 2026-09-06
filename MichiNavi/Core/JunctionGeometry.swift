import CoreGraphics
import CoreLocation
import MapKit

/// 経路から測った、入ってくる向きを基準とする出口の角度。
///
/// CarPlay がロータリーの `CPManeuver.junctionExitAngle` として車のメーター・HUD へ送る。
/// ここでは測定だけを行い、CarPlay の型への変換は表示層で行う。
/// 計算中の座標系はメートル・進行方向が +y。入ってくる向きが変わっても同じ角度を返す。
struct JunctionGeometry {
    /// 出ていく向きが、入ってくる向きからどれだけ振れているか（ラジアン）。
    /// 0 が直進、正が右。
    let turn: CGFloat

    /// 向きの測定に使う、曲がる地点の手前と先の範囲。
    private static let approachDistance: CLLocationDistance = 100
    private static let departureDistance: CLLocationDistance = 100

    /// 向きを決めるために遡る／先を見る距離。直前の 1 点だけで決めると、交差点の中の
    /// 細かい点で向きが跳ねる。
    private static let headingSample: CLLocationDistance = 25

    /// `stepIndex` の区間の終わり（＝曲がる地点）の角度。測れなければ nil。
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
        let rotatedDeparture = departure.map { rotate($0, by: angle) }

        guard let turn = turnAngle(departure: rotatedDeparture) else { return nil }
        return JunctionGeometry(turn: turn)
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
