import CoreLocation
import MapKit
import UIKit

/// 曲がる地点の前後だけを切り出して、交差点の拡大図を描く。
///
/// **MapKit は交差点の形も、通らない側の道も、車線も返さない**ので、市販ナビのような
/// 拡大図は作れない。代わりに**経路そのものの形**を曲がる地点のまわりだけ拡大して描く。
/// 矢印アイコンでは「右折」としか分からないところが、**30 度の分岐なのか直角なのか、
/// 曲がったあとすぐまた曲がるのか**まで出る。でっち上げた交差点ではなく実際にたどる線なので、
/// データが無いことを理由に外すことがない。
///
/// 逆に**描けないもの**もはっきりしている。交わる側の道、信号、車線、標識。
/// それらしく描くとかえって「そこに道がある」と誤解させるので、線 1 本に留める。
enum JunctionImage {
    /// CarPlay に渡せる上限（`CPManeuver.junctionImage` のヘッダに明記）。
    /// 超えると縮小されるので、最初からこの寸法で描く。
    static let size = CGSize(width: 140, height: 100)

    /// 曲がる地点の手前と先を、それぞれどれだけ入れるか。
    ///
    /// 広げるほど縮尺が小さくなり、肝心の曲がり角が潰れる。**曲がる直前に見て分かる
    /// 範囲**に絞る。
    private static let approachDistance: CLLocationDistance = 100
    private static let departureDistance: CLLocationDistance = 100

    /// 進行方向を決めるために遡る距離。直前の 1 点だけで決めると、経路の座標が
    /// 細かいところで向きが跳ねる。
    private static let headingSample: CLLocationDistance = 25

    /// 描画範囲の最小の広がり（メートル）。
    ///
    /// **これが無いと、ほぼ直進の分岐で縮尺が発散する。** 前後がまっすぐ並ぶと
    /// 横幅がほぼ 0 になり、そこへ画面いっぱいまで拡大しようとする。
    private static let minimumExtent: Double = 70

    /// これより浅い曲がりでは描かない（ラジアン）。
    ///
    /// **ほぼまっすぐな線の図は、矢印アイコン以上のことを何も言わない。** 案内カードの
    /// 場所だけ取って読む理由が無いので出さない。車線を寄せるだけの指示はたいていここで
    /// 落ちるが、分岐が実際に開いていれば残る（実路 28 か所で確認）。
    private static let minimumTurn: CGFloat = 20 * .pi / 180

    private static let padding: CGFloat = 10
    private static let departureLineWidth: CGFloat = 5
    private static let approachLineWidth: CGFloat = 3.5

    /// `stepIndex` の区間の終わり（＝曲がる地点）の拡大図。描けなければ nil。
    ///
    /// **曲がらない指示では描かない。** 直進・到着・出発で道の形だけ出しても読む理由が
    /// 無いうえ、案内カードの場所を取る。
    static func make(for route: NavRoute, stepIndex: Int, direction: ManeuverDirection) -> UIImage? {
        switch direction {
        case .straight, .depart, .arrive, .unknown: return nil
        default: break
        }

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

        // 進行方向が上を向くように回す。北上げのままだと、同じ右折でも走っている
        // 向きによって絵が変わり、見比べられない。
        guard let heading = heading(of: approach) else { return nil }
        let angle = atan2(heading.x, heading.y)
        let rotatedApproach = approach.map { rotate($0, by: angle) }
        let rotatedDeparture = departure.map { rotate($0, by: angle) }

        guard let turn = turnAngle(departure: rotatedDeparture), abs(turn) >= minimumTurn else {
            return nil
        }
        return render(approach: rotatedApproach, departure: rotatedDeparture)
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

    // MARK: - 描画

    /// **自前の背景を敷く。** 案内カードの色はこちらが `guidanceBackgroundColor` で
    /// `systemBlue` にしているので、経路と同じ青で線を引くと見えない。Dashboard の
    /// カードは CarPlay が昼夜で塗り分けるうえ、こちらから色を渡す口が無い。
    /// 図の中で明暗を完結させておけば、どの背景の上でも読める。
    private static func render(approach: [CGPoint], departure: [CGPoint]) -> UIImage? {
        let all = approach + departure
        guard let bounds = fittingTransform(for: all) else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        // 車の画面の倍率はこちらから決められないので、いちばん細かいところに合わせて
        // 固定する。上限どおりの寸法なので、縮小されても潰れない。
        format.scale = 3
        format.opaque = false

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext

            UIColor.black.withAlphaComponent(0.28).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 10).fill()

            cg.setLineCap(.round)
            cg.setLineJoin(.round)

            stroke(approach.map(bounds), on: cg,
                   color: UIColor.white.withAlphaComponent(0.45), width: approachLineWidth)
            stroke(departure.map(bounds), on: cg,
                   color: .white, width: departureLineWidth)

            drawArrowHead(at: departure.map(bounds), on: cg)
        }
    }

    private static func stroke(_ points: [CGPoint], on context: CGContext, color: UIColor, width: CGFloat) {
        guard points.count >= 2 else { return }
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.beginPath()
        context.move(to: points[0])
        for point in points.dropFirst() { context.addLine(to: point) }
        context.strokePath()
    }

    /// 進む先に矢じりを置く。**どちらへ抜けるのかを線だけで示せない**ため。
    private static func drawArrowHead(at points: [CGPoint], on context: CGContext) {
        guard let tip = points.last, points.count >= 2 else { return }
        // 末端がごく短い線分だと向きが暴れるので、少し手前から向きを取る。
        let base = points[max(points.count - 3, 0)]
        let vector = CGPoint(x: tip.x - base.x, y: tip.y - base.y)
        let length = hypot(vector.x, vector.y)
        guard length > 0 else { return }

        let unit = CGPoint(x: vector.x / length, y: vector.y / length)
        let normal = CGPoint(x: -unit.y, y: unit.x)
        let size: CGFloat = 9

        context.setFillColor(UIColor.white.cgColor)
        context.beginPath()
        context.move(to: tip)
        context.addLine(to: CGPoint(x: tip.x - unit.x * size + normal.x * size * 0.55,
                                    y: tip.y - unit.y * size + normal.y * size * 0.55))
        context.addLine(to: CGPoint(x: tip.x - unit.x * size - normal.x * size * 0.55,
                                    y: tip.y - unit.y * size - normal.y * size * 0.55))
        context.closePath()
        context.fillPath()
    }

    /// メートル座標を画面座標へ移す関数を作る。縦横は同じ倍率で、全体が収まるように寄せる。
    private static func fittingTransform(for points: [CGPoint]) -> ((CGPoint) -> CGPoint)? {
        guard !points.isEmpty else { return nil }

        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let centre = CGPoint(x: (xs.min()! + xs.max()!) / 2, y: (ys.min()! + ys.max()!) / 2)
        // ほぼ直進の分岐で横幅が 0 になると縮尺が発散するので、下限を入れる。
        let width = max(xs.max()! - xs.min()!, minimumExtent)
        let height = max(ys.max()! - ys.min()!, minimumExtent)

        let usable = CGSize(width: size.width - padding * 2, height: size.height - padding * 2)
        let scale = min(usable.width / width, usable.height / height)

        return { point in
            CGPoint(x: size.width / 2 + (point.x - centre.x) * scale,
                    // メートル座標は北が +y、画面は下が +y。
                    y: size.height / 2 - (point.y - centre.y) * scale)
        }
    }
}
