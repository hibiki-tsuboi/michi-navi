import UIKit

/// 道路番号を標識の形に描く。案内文に差し込む小さな画像。
///
/// **上限は 64×25pt**（`CPManeuver.attributedInstructionVariants` のヘッダに明記。
/// 添付できるのはテキストアタッチメントだけで、ほかの属性はすべて剥がされる）。
///
/// 形と色は日本の案内標識に合わせる。国道は青い逆三角（おにぎり）、都道府県道は
/// 青い六角形、都市高速は緑。**それらしい別の形にしない**。番号を読むより先に形で
/// 見分けているので、形が違うと逆に遅くなる。
enum RoadShieldImage {
    /// 上限は 64×25pt。**国道だけ寸法が別**なのは、逆三角が下へ向かって細くなるため。
    /// 同じ幅では 3 桁の数字が斜めの縁に当たる（実測でそうなった）。
    private static func size(for road: RoadNumber, digits: Int) -> CGSize {
        if case .national = road {
            return CGSize(width: min(CGFloat(digits) * 15 + 20, 64), height: 25)
        }
        return CGSize(width: min(CGFloat(digits) * 11 + 16, 64), height: 22)
    }

    /// 3 桁は字を落とす。逆三角の広いところに収めるにはこれ以上大きくできない。
    private static func fontSize(for road: RoadNumber, digits: Int) -> CGFloat {
        if case .national = road, digits >= 3 { return 10 }
        return 12
    }

    static func make(for road: RoadNumber) -> UIImage? {
        let text = String(road.number)
        let size = size(for: road, digits: text.count)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 3
        format.opaque = false

        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            // **白い縁を付ける。** 標識の紺は案内カードの青と近く、縁が無いと形が溶ける
            // （実測: `systemBlue` の上でそう見えた）。実際の案内標識も白で縁取られている。
            let shape = path(for: road, in: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1))
            color(for: road).setFill()
            shape.fill()
            UIColor.white.setStroke()
            shape.lineWidth = 1.5
            shape.stroke()

            // 白抜きの数字。標識は必ず白文字なので、下地の色に関わらず白で固定。
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize(for: road, digits: text.count), weight: .bold),
                .foregroundColor: UIColor.white,
            ]
            let bounds = (text as NSString).size(withAttributes: attributes)

            // **逆三角では中央に置かない。** 下へ行くほど細いので、いちばん広い上寄りに置く。
            let y: CGFloat = {
                if case .national = road { return 3 }
                return (size.height - bounds.height) / 2
            }()
            (text as NSString).draw(at: CGPoint(x: (size.width - bounds.width) / 2, y: y),
                                    withAttributes: attributes)
        }
    }

    private static func color(for road: RoadNumber) -> UIColor {
        switch road {
        // 案内標識の青。CarPlay の案内カードも青なので、少し濃くして沈ませない。
        case .national, .prefectural: UIColor(red: 0.05, green: 0.24, blue: 0.55, alpha: 1)
        // 高速の案内標識は緑。
        case .expressway: UIColor(red: 0.05, green: 0.38, blue: 0.24, alpha: 1)
        }
    }

    private static func path(for road: RoadNumber, in rect: CGRect) -> UIBezierPath {
        switch road {
        case .national:
            // おにぎり（角を丸めた逆三角）。
            let path = UIBezierPath()
            path.move(to: CGPoint(x: rect.minX + 1, y: rect.minY + 2))
            path.addLine(to: CGPoint(x: rect.maxX - 1, y: rect.minY + 2))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - 1))
            path.close()
            return path

        case .prefectural:
            // 六角形（上下が尖った形）。
            let path = UIBezierPath()
            let inset = rect.width * 0.18
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + inset))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - inset))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - inset))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + inset))
            path.close()
            return path

        case .expressway:
            return UIBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 1), cornerRadius: 4)
        }
    }
}
