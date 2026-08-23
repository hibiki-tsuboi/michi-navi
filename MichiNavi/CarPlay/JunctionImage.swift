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
///
/// **形を測るのは `JunctionGeometry`（`Core/`）**。同じ測定から車へ送る角度
/// （`CPManeuver.junctionExitAngle`）も作るので、絵と数字が食い違わない。
enum JunctionImage {
    /// CarPlay に渡せる上限（`CPManeuver.junctionImage` のヘッダに明記）。
    /// 超えると縮小されるので、最初からこの寸法で描く。
    static let size = CGSize(width: 140, height: 100)

    /// 描画範囲の最小の広がり（メートル）。
    ///
    /// **これが無いと、ごく短い区間が画面いっぱいに引き伸ばされる。** 枠に収める条件
    /// だけで倍率を決めると、5m の区間が道 1 本ぶんの長さで描かれ、実際より大きな
    /// 交差点に見える（下限を外すと 60pt まで伸びる）。
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

    /// 矢じりの長さと、中心から片側への張り出し。**線の幅よりはっきり大きくする。**
    /// 2026-08-23 まで長さ 9・張り出し 5 で、線の幅 5 とほとんど変わらなかった。
    /// そこへ丸い線端（半径 2.5）が先から飛び出すので、**矢印ではなく画鋲に見えていた**。
    private static let arrowLength: CGFloat = 15
    private static let arrowHalfWidth: CGFloat = 9

    /// 曲がる地点を絵のどこに置くか（縦の割合）。
    ///
    /// **中央ではなく少し下。** 入ってくる道は「もう走ったところ」なので短くてよく、
    /// 出ていく道に場所を譲る。曲がる地点がいつも同じ高さに来るので、**どこを見れば
    /// よいかが図ごとに変わらない**。
    ///
    /// 2026-08-23 まで外接矩形の中心に合わせていた。あれだと L 字の 90 度で
    /// **角が隅へ寄って半分が空白になる**（実際に描いて確かめた）。
    private static let junctionAnchorY: CGFloat = 0.7

    /// 入ってくる道を画面上でどれだけ見せるか（ポイント）。
    ///
    /// **メートルではなくポイントで切る。** あちらは「どこから来たか」の目印でしかないのに、
    /// 縮尺を決める側に混ぜると 100m ぶんを収めるために出ていく道が潰れる
    /// （実測: 90 度の右折で出ていく道が 18pt になり、矢じりだけの絵になった）。
    private static let approachStubLength: CGFloat = 18

    /// 曲がる向きと逆へ基準をずらす量（横幅の割合）。
    private static let junctionAnchorBias: CGFloat = 0.18

    /// 曲がる地点の拡大図。描けなければ nil。
    ///
    /// **曲がらない指示では描かない。** 直進・到着・出発で道の形だけ出しても読む理由が
    /// 無いうえ、案内カードの場所を取る。
    static func make(for geometry: JunctionGeometry, direction: ManeuverDirection) -> UIImage? {
        switch direction {
        case .straight, .depart, .arrive, .unknown: return nil
        default: break
        }
        guard abs(geometry.turn) >= minimumTurn else { return nil }
        return render(approach: geometry.approach, departure: geometry.departure)
    }

    // MARK: - 描画

    /// **自前の背景を敷く。** 案内カードの色はこちらが `guidanceBackgroundColor` で
    /// `systemBlue` にしているので、経路と同じ青で線を引くと見えない。Dashboard の
    /// カードは CarPlay が昼夜で塗り分けるうえ、こちらから色を渡す口が無い。
    /// 図の中で明暗を完結させておけば、どの背景の上でも読める。
    private static func render(approach: [CGPoint], departure: [CGPoint]) -> UIImage? {
        // **縮尺を決めるのは出ていく道だけ**（[approachStubLength]）。
        guard let bounds = fittingTransform(for: departure) else { return nil }

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

            let departurePoints = departure.map(bounds)
            stroke(clipped(approach.map(bounds), toLast: approachStubLength), on: cg,
                   color: UIColor.white.withAlphaComponent(0.45), width: approachLineWidth)
            // **矢じりに隠れるぶんだけ手前で止める。** 丸い線端が矢じりの先から
            // 飛び出すと、矢印に見えなくなる。向きは削る前の点から取る。
            stroke(trimmed(departurePoints, by: arrowLength * 0.8), on: cg,
                   color: .white, width: departureLineWidth)

            drawArrowHead(at: departurePoints, on: cg)
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

        context.setFillColor(UIColor.white.cgColor)
        context.beginPath()
        context.move(to: tip)
        context.addLine(to: CGPoint(x: tip.x - unit.x * arrowLength + normal.x * arrowHalfWidth,
                                    y: tip.y - unit.y * arrowLength + normal.y * arrowHalfWidth))
        context.addLine(to: CGPoint(x: tip.x - unit.x * arrowLength - normal.x * arrowHalfWidth,
                                    y: tip.y - unit.y * arrowLength - normal.y * arrowHalfWidth))
        context.closePath()
        context.fillPath()
    }

    /// 末尾から `length` ぶんだけ残した線。入ってくる道を目印の長さに切るために使う。
    private static func clipped(_ points: [CGPoint], toLast length: CGFloat) -> [CGPoint] {
        guard points.count >= 2, let end = points.last else { return points }

        var result = [end]
        var previous = end
        var travelled: CGFloat = 0
        for point in points.dropLast().reversed() {
            let span = hypot(point.x - previous.x, point.y - previous.y)
            guard travelled + span < length else {
                let ratio = span > 0 ? (length - travelled) / span : 0
                result.insert(CGPoint(x: previous.x + (point.x - previous.x) * ratio,
                                      y: previous.y + (point.y - previous.y) * ratio), at: 0)
                return result
            }
            travelled += span
            previous = point
            result.insert(point, at: 0)
        }
        return result
    }

    /// 末尾を `length` ぶん削った線。矢じりの下に線端を隠すために使う。
    ///
    /// 最後の区間より深く削るときは、その区間ごと落として手前から削り直す
    /// （交差点の中は点が細かいので、1 区間が数ポイントしかないことがある）。
    private static func trimmed(_ points: [CGPoint], by length: CGFloat) -> [CGPoint] {
        guard points.count >= 2, let tip = points.last else { return points }

        let previous = points[points.count - 2]
        let vector = CGPoint(x: tip.x - previous.x, y: tip.y - previous.y)
        let span = hypot(vector.x, vector.y)
        guard span > 0 else { return Array(points.dropLast()) }

        if span <= length {
            return trimmed(Array(points.dropLast()), by: length - span)
        }
        let ratio = (span - length) / span
        var result = points
        result[result.count - 1] = CGPoint(x: previous.x + vector.x * ratio,
                                           y: previous.y + vector.y * ratio)
        return result
    }

    /// メートル座標を画面座標へ移す関数を作る。縦横は同じ倍率。
    ///
    /// **基準は曲がる地点（原点）で、外接矩形の中心ではない。** 外接矩形に合わせると、
    /// L 字の 90 度で角が隅へ寄って半分が空白になる。曲がる地点を決まった場所に置けば、
    /// **どの図でも同じところを見れば曲がり方が分かる**。
    ///
    /// 倍率は「その基準のまま全部が枠に収まる最大」を点ごとに詰めて決める。
    ///
    /// **テストから触れるようにしてある。** 絵が読めるかどうかは目でしか決まらないが、
    /// **縮尺が潰れたこと**（出ていく道が数ポイントになる）は数字で捕まえられる。
    /// U ターンで実際に潰れたので、そこだけは落ちるようにしておく。
    static func fittingTransform(for points: [CGPoint]) -> ((CGPoint) -> CGPoint)? {
        guard !points.isEmpty else { return nil }

        // **曲がる向きと逆へ基準をずらす。** 出ていく道は片側にしか伸びないので、
        // 真ん中に置くと反対側が丸ごと空く（実際に描いて確かめた: 右折で左半分が空白）。
        // ずらしたぶん出ていく道に幅が回り、同じ枠でも矢印が大きく描ける。
        let furthestX = points.map(\.x).max(by: { abs($0) < abs($1) }) ?? 0
        let bias: CGFloat = abs(furthestX) < 1 ? 0 : (furthestX > 0 ? -junctionAnchorBias : junctionAnchorBias)
        // **縦も同じ**。折り返し（U ターン）では出ていく道が下へ戻るので、基準を下に
        // 置いたままだと収める場所が無くて縮尺が潰れる（実際に描いて確かめた:
        // 絵が塊になった）。そのときだけ基準を上へ寄せる。
        let furthestY = points.map(\.y).max(by: { abs($0) < abs($1) }) ?? 0
        let anchorY = furthestY < -1 ? 1 - junctionAnchorY : junctionAnchorY
        let anchor = CGPoint(x: size.width * (0.5 + bias), y: size.height * anchorY)
        let room = (left: anchor.x - padding,
                    right: size.width - padding - anchor.x,
                    up: anchor.y - padding,
                    down: size.height - padding - anchor.y)

        // ほぼ直進の分岐では点が縦一列に並び、倍率がいくらでも大きくなる。
        // **下限の広がり**（`minimumExtent`）を超えて拡大しない。
        let usable = min(size.width - padding * 2, size.height - padding * 2)
        var scale = usable / minimumExtent
        for point in points {
            if point.x > 0 { scale = min(scale, room.right / point.x) }
            if point.x < 0 { scale = min(scale, room.left / -point.x) }
            if point.y > 0 { scale = min(scale, room.up / point.y) }
            if point.y < 0 { scale = min(scale, room.down / -point.y) }
        }
        guard scale > 0 else { return nil }

        return { point in
            // メートル座標は北が +y、画面は下が +y。
            CGPoint(x: anchor.x + point.x * scale, y: anchor.y - point.y * scale)
        }
    }
}
