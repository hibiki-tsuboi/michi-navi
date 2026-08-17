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
