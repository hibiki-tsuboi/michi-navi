import CoreLocation
import MapKit

/// 案内中の「いまどこまで進んだか」を表すスナップショット。
struct RouteProgress {
    /// いま走行中の step の添字。`route.steps[stepIndex].instruction` が次の指示。
    let stepIndex: Int
    /// 次に曲がる地点までの距離。
    let distanceToNextManeuver: CLLocationDistance
    /// 目的地までの残り距離。
    let distanceRemaining: CLLocationDistance
    /// 目的地までの残り時間。
    let timeRemaining: TimeInterval
    /// 経路に吸着させた表示用の座標。
    let snappedCoordinate: CLLocationCoordinate2D
    /// 経路からの横方向のずれ。
    let distanceFromRoute: CLLocationDistance
    /// 経路を外れたと判定された。
    let isOffRoute: Bool
    /// 目的地に到着した。
    let hasArrived: Bool

    var arrivalDate: Date { Date(timeIntervalSinceNow: timeRemaining) }
}

/// 位置更新のたびに経路上の進捗を計算する。ルート 1 本につき 1 インスタンス。
///
/// 距離計算は `MKMapPoint`（メルカトル平面）上で行い、最後にメートルへ換算する。
/// 数十メートル規模では平面近似の誤差は無視できる。
final class GuidanceEngine {
    /// 経路中心線からこれ以上離れたら逸脱候補とみなす。
    private let offRouteThreshold: CLLocationDistance = 50
    /// 逸脱候補が続けてこの回数出たらリルートする。GPS の跳ねで誤爆しないための保険。
    private let offRouteConfirmationCount = 3
    /// 目的地にこれだけ近づいたら到着とみなす。
    private let arrivalThreshold: CLLocationDistance = 30

    private let route: NavRoute
    private let points: [MKMapPoint]
    /// points[i] までの累積距離（メートル）。
    private let cumulativeDistances: [CLLocationDistance]
    private let totalDistance: CLLocationDistance

    /// 前回スナップした区間。次回はこの周辺だけ探すことで、
    /// ループ路や折り返しで経路の別の場所に飛びつくのを防ぐ。
    private var lastSegmentIndex = 0
    private var offRouteStreak = 0

    /// 最後の測位で経路上をどこまで進んでいたか。測位が途切れたときの推測の起点。
    private var lastTravelled: CLLocationDistance = 0
    /// 最後の測位での速度（m/s）。`CLLocation.speed` は取れないとき負を返すので、
    /// そのときは経路全体の平均速度で代える。
    private var lastSpeed: CLLocationSpeed = 0

    init(route: NavRoute) {
        self.route = route
        points = route.coordinates.map { MKMapPoint($0) }

        var cumulative: [CLLocationDistance] = [0]
        cumulative.reserveCapacity(points.count)
        for i in 1 ..< max(points.count, 1) {
            cumulative.append(cumulative[i - 1] + points[i].distance(to: points[i - 1]))
        }
        cumulativeDistances = cumulative
        totalDistance = cumulative.last ?? route.distance
    }

    func update(with location: CLLocation) -> RouteProgress {
        guard points.count >= 2 else {
            return RouteProgress(stepIndex: 0,
                                 distanceToNextManeuver: 0,
                                 distanceRemaining: 0,
                                 timeRemaining: 0,
                                 snappedCoordinate: location.coordinate,
                                 distanceFromRoute: 0,
                                 isOffRoute: false,
                                 hasArrived: true)
        }

        let match = nearestPointOnRoute(to: MKMapPoint(location.coordinate))
        lastSegmentIndex = match.segmentIndex

        let travelled = cumulativeDistances[match.segmentIndex] + match.distanceIntoSegment

        // 逸脱判定。1 回外れただけでは切り替えず、連続で外れたときだけ確定させる。
        //
        // **測位の誤差がしきい値より大きい間は数えない**。誤差 100m の位置で
        // 「中心線から 50m 以上離れている」とは言い切れないため。ビルの谷間や
        // トンネル前後でこれを数えると、実際には経路上にいるのにリルートが連発する。
        // 経路に戻ったときの解除は精度に関係なく効かせる（早く戻すほうが安全側）。
        if match.lateralDistance <= offRouteThreshold {
            offRouteStreak = 0
        } else if location.horizontalAccuracy >= 0, location.horizontalAccuracy <= offRouteThreshold {
            offRouteStreak += 1
        }

        lastTravelled = travelled
        lastSpeed = location.speed >= 0 ? location.speed : averageSpeed

        return progress(travelled: travelled,
                        snappedTo: match.point.coordinate,
                        distanceFromRoute: match.lateralDistance,
                        isOffRoute: offRouteStreak >= offRouteConfirmationCount,
                        canArrive: true)
    }

    /// 測位が途切れているあいだ、最後の速度で経路上を進めた進捗を作る。
    ///
    /// トンネルの中では GPS が来ない。位置更新のたびに動く作りのままだと、入った瞬間の
    /// 案内で止まり、出口の分岐に気づけない。実際のカーナビが必ず持っている推測航法の、
    /// いちばん素朴な形（経路上を等速で進める）を置いてある。
    ///
    /// **経路の逸脱と到着はここでは判定しない。** どちらも「実際にどこにいるか」の話で、
    /// 推測で言い切ってよいものではない。推測でリルートすれば道なりに走っているのに
    /// 経路が入れ替わり、推測で到着すれば案内がトンネルの中で終わる。
    ///
    /// - Parameter elapsed: 最後の測位からの経過時間。
    func extrapolate(elapsed: TimeInterval) -> RouteProgress? {
        guard points.count >= 2, lastSpeed > 0, elapsed > 0 else { return nil }

        let travelled = min(lastTravelled + lastSpeed * elapsed, totalDistance)
        return progress(travelled: travelled,
                        snappedTo: coordinate(atTravelled: travelled),
                        distanceFromRoute: 0,
                        isOffRoute: false,
                        canArrive: false)
    }

    /// 経路上の進んだ距離から進捗を組み立てる。実測と推測で共通。
    private func progress(travelled: CLLocationDistance,
                          snappedTo coordinate: CLLocationCoordinate2D,
                          distanceFromRoute: CLLocationDistance,
                          isOffRoute: Bool,
                          canArrive: Bool) -> RouteProgress {
        let remaining = max(totalDistance - travelled, 0)
        let stepIndex = currentStepIndex(travelled: travelled)
        let stepEnd = cumulativeDistances[route.stepEndIndices[stepIndex]]

        // 残り時間は残距離に比例させる。MKRoute は step ごとの所要時間を返さないため、
        // これが MapKit だけで出せる最良の近似になる。
        let ratio = totalDistance > 0 ? remaining / totalDistance : 0

        return RouteProgress(stepIndex: stepIndex,
                             distanceToNextManeuver: max(stepEnd - travelled, 0),
                             distanceRemaining: remaining,
                             timeRemaining: route.expectedTravelTime * ratio,
                             snappedCoordinate: coordinate,
                             distanceFromRoute: distanceFromRoute,
                             isOffRoute: isOffRoute,
                             hasArrived: canArrive && remaining <= arrivalThreshold)
    }

    /// 経路の始点から `travelled` メートル進んだ地点。
    private func coordinate(atTravelled travelled: CLLocationDistance) -> CLLocationCoordinate2D {
        guard let index = cumulativeDistances.firstIndex(where: { $0 >= travelled }) else {
            return points.last?.coordinate ?? route.coordinates[0]
        }
        guard index > 0 else { return points[0].coordinate }

        let spanStart = cumulativeDistances[index - 1]
        let span = cumulativeDistances[index] - spanStart
        let t = span > 0 ? (travelled - spanStart) / span : 0
        let a = points[index - 1]
        let b = points[index]
        return MKMapPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t).coordinate
    }

    /// 経路全体の平均速度。`CLLocation.speed` が取れないときの代わり。
    private var averageSpeed: CLLocationSpeed {
        route.expectedTravelTime > 0 ? route.distance / route.expectedTravelTime : 0
    }

    // MARK: - 経路への吸着

    private struct RouteMatch {
        let segmentIndex: Int
        let point: MKMapPoint
        let distanceIntoSegment: CLLocationDistance
        let lateralDistance: CLLocationDistance
    }

    private func nearestPointOnRoute(to target: MKMapPoint) -> RouteMatch {
        // 通常は前回位置の前後だけを探す。見つからなければ経路全体を探し直す
        // （トンネルを抜けた直後や、案内開始時に大きく飛ぶケース）。
        let window = 30
        let nearby = max(lastSegmentIndex - 5, 0) ... min(lastSegmentIndex + window, points.count - 2)

        if let match = bestMatch(to: target, in: nearby), match.lateralDistance <= offRouteThreshold {
            return match
        }
        return bestMatch(to: target, in: 0 ... (points.count - 2)) ?? RouteMatch(segmentIndex: lastSegmentIndex,
                                                                                point: target,
                                                                                distanceIntoSegment: 0,
                                                                                lateralDistance: .greatestFiniteMagnitude)
    }

    private func bestMatch(to target: MKMapPoint, in range: ClosedRange<Int>) -> RouteMatch? {
        var best: RouteMatch?

        for i in range {
            let projected = project(target, onto: points[i], points[i + 1])
            let lateral = projected.distance(to: target)
            if lateral < (best?.lateralDistance ?? .greatestFiniteMagnitude) {
                best = RouteMatch(segmentIndex: i,
                                  point: projected,
                                  distanceIntoSegment: projected.distance(to: points[i]),
                                  lateralDistance: lateral)
            }
        }
        return best
    }

    /// 線分 a-b 上で target にいちばん近い点を返す。
    private func project(_ target: MKMapPoint, onto a: MKMapPoint, _ b: MKMapPoint) -> MKMapPoint {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return a }

        // 線分外にはみ出さないよう 0...1 に丸める。
        let t = min(max(((target.x - a.x) * dx + (target.y - a.y) * dy) / lengthSquared, 0), 1)
        return MKMapPoint(x: a.x + t * dx, y: a.y + t * dy)
    }

    private func currentStepIndex(travelled: CLLocationDistance) -> Int {
        for (index, endIndex) in route.stepEndIndices.enumerated()
        where cumulativeDistances[endIndex] > travelled {
            return index
        }
        return max(route.steps.count - 1, 0)
    }
}
