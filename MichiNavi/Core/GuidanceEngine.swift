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
    /// 一度でも経路の上に乗ったか。
    ///
    /// **外れているのに引き直しが走らない状態**（駐車場や施設の中から始めたとき）を
    /// 外から見分けるために出している。逸脱と違って「まだ案内が始まっていない」に
    /// 近いので、CarPlay はここを見て案内カードを「経路へ進む」に差し替える。
    let hasJoinedRoute: Bool

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
    /// 経路に乗らないまま出発地からこれだけ離れたら、乗っていなくても逸脱を数え始める。
    private let departureThreshold: CLLocationDistance = 100
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

    /// 一度でも経路の上に乗ったか。**乗るまでは逸脱を数えない。**
    ///
    /// MapKit は経路の始点を最寄りの車道へ寄せるので、駐車場・駅・施設の中から
    /// 案内を始めると**動く前から中心線の外に居る**（実測で Apple Park の中央から
    /// 312m、東京駅から 228m。しきい値の 50m をはるかに超える）。そこを逸脱として
    /// 数えると、止まったまま引き直しが走る。しかも引き直しても始点は同じ車道へ
    /// 寄るので何も変わらず、「再検索中」のカードと「ルートを再検索しました」の
    /// 読み上げが数秒おきに繰り返される。
    private var hasJoinedRoute = false

    /// 最初の測位の位置。経路に乗らないまま走り出したときに判定を復活させる基準
    /// （[departureThreshold]）。**これが無いと、駐車場から経路とは別の道へ出た場合に
    /// 最後まで一度も引き直せなくなる。**
    private var startPoint: MKMapPoint?

    /// 交通状況で測り直した残り時間の基準点。「あの地点で残り N 秒」を覚えておき、
    /// 以降はそこからの距離比で減らす。
    ///
    /// **出発時の見積もりを全体の距離で按分しない**理由がここにある。按分は渋滞に入っても
    /// 数字が動かず、運転者がいちばん見る数字がいちばん当たらなくなる。基準点を置き直せば、
    /// 少なくとも最後に測った時点の混み具合までは反映される。
    private var timeReference: (remaining: CLLocationDistance, time: TimeInterval)?

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

    /// いま測り直した残り時間を反映する。以降の進捗はここを起点に減る。
    ///
    /// 呼ぶ側は**引き直しを挟んでいないこと**を確かめること。経路が入れ替わっていれば
    /// この engine ごと作り直されているので、古い経路で測った時間が紛れ込むことはない。
    func applyMeasuredTimeRemaining(_ time: TimeInterval) {
        timeReference = (remaining: max(totalDistance - lastTravelled, 0), time: time)
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
                                 hasArrived: true,
                                 // 点が足りず経路として成立していない。案内する先が無いので
                                 // 「経路へ進む」を出しても行き場が無い。乗った扱いにする。
                                 hasJoinedRoute: true)
        }

        let target = MKMapPoint(location.coordinate)
        if startPoint == nil { startPoint = target }

        let match = nearestPointOnRoute(to: target)
        lastSegmentIndex = match.segmentIndex

        let travelled = cumulativeDistances[match.segmentIndex] + match.distanceIntoSegment

        // 逸脱判定。1 回外れただけでは切り替えず、連続で外れたときだけ確定させる。
        //
        // **まだ経路に乗っていないうちは数えない**（[hasJoinedRoute]）。
        // **測位の誤差がしきい値より大きい間も数えない**。誤差 100m の位置で
        // 「中心線から 50m 以上離れている」とは言い切れないため。ビルの谷間や
        // トンネル前後でこれを数えると、実際には経路上にいるのにリルートが連発する。
        // 経路に戻ったときの解除はどちらの条件にも関係なく効かせる（早く戻すほうが安全側）。
        if match.lateralDistance <= offRouteThreshold {
            hasJoinedRoute = true
            offRouteStreak = 0
        } else if canJudgeOffRoute(at: target),
                  location.horizontalAccuracy >= 0,
                  location.horizontalAccuracy <= offRouteThreshold {
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

    /// 逸脱を数えてよいか。経路に乗ったあとか、乗らないまま出発地から離れたあと。
    ///
    /// 後者が要るのは、駐車場から経路とは別の道へ出ていく場合があるため。そこを
    /// 「乗るまで数えない」だけで塞ぐと、**一度も引き直せないまま案内が続く**という、
    /// 直そうとしている症状より悪い状態になる。
    private func canJudgeOffRoute(at target: MKMapPoint) -> Bool {
        if hasJoinedRoute { return true }
        guard let startPoint else { return false }
        return startPoint.distance(to: target) > departureThreshold
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
    /// **到着圏に入る手前で推測をやめる**（`nil` を返す）。推測で到着を言わないのなら、
    /// 到着と同じ距離まで推測で詰めてもいけない。以前は `min(..., totalDistance)` で
    /// 経路の端に張り付かせていたので、測位が戻らないときに**「残り 0m」を出したまま
    /// 永遠に到着しない**状態になった。0m と言いながら着かないのは、案内としていちばん
    /// 読めない形——**分かっているところまでしか言わない**ほうがよい。進めるのをやめれば
    /// 表示は最後に測れた値で止まる。
    ///
    /// - Parameter elapsed: 最後の測位からの経過時間。
    func extrapolate(elapsed: TimeInterval) -> RouteProgress? {
        guard points.count >= 2, lastSpeed > 0, elapsed > 0 else { return nil }

        let travelled = lastTravelled + lastSpeed * elapsed
        guard travelled < totalDistance - arrivalThreshold else { return nil }
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

        return RouteProgress(stepIndex: stepIndex,
                             distanceToNextManeuver: max(stepEnd - travelled, 0),
                             distanceRemaining: remaining,
                             timeRemaining: timeRemaining(at: remaining),
                             snappedCoordinate: coordinate,
                             distanceFromRoute: distanceFromRoute,
                             isOffRoute: isOffRoute,
                             hasArrived: canArrive && remaining <= arrivalThreshold,
                             hasJoinedRoute: hasJoinedRoute)
    }

    /// 残り時間。**測り直した基準点があればそこから、無ければ出発時の見積もりを按分する。**
    ///
    /// どちらも残距離への比例で、違うのは何を基準に比例させるか。MKRoute は step ごとの
    /// 所要時間を返さないので、比例以上のことは MapKit だけではできない。
    private func timeRemaining(at remaining: CLLocationDistance) -> TimeInterval {
        if let timeReference, timeReference.remaining > 0 {
            return timeReference.time * (remaining / timeReference.remaining)
        }
        guard totalDistance > 0 else { return 0 }
        return route.expectedTravelTime * (remaining / totalDistance)
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
