import UIKit

/// 案内カードに、これから入る道路を大きな文字で示す。
/// 交差点の画像枠を使うが、経路の形や次の次の操作は描かない。
enum RoadNameImage {
    private static let size = CGSize(width: 140, height: 100)
    private static let textArea = CGRect(x: 8, y: 30, width: 124, height: 62)

    static func make(for roadName: String?, direction: ManeuverDirection,
                     signpost: ManeuverInstruction.Signpost? = nil) -> UIImage? {
        // 直進や到着で「〜へ」と出すと、別の道路へ曲がる指示に見えてしまう。
        switch direction {
        case .straight, .depart, .arrive, .unknown: return nil
        default: break
        }
        let title: String
        let caption: String
        if let signpost {
            // 高速では道路名より、標識と照合する方面・出口名を優先する。
            title = signpost.title
            caption = signpost.caption
        } else {
            guard let roadName, !roadName.isEmpty else { return nil }
            title = String(localized: "\(roadName)へ")
            caption = String(localized: "進む道路")
        }
        guard let layout = layout(for: title) else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 3
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            // 昼夜とも白い文字を読める下地を画像自身が持つ。車やDashboardの背景色に依存しない。
            UIColor(red: 0.06, green: 0.18, blue: 0.32, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8).fill()
            let border = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1),
                                      cornerRadius: 7)
            UIColor.white.withAlphaComponent(0.65).setStroke()
            border.lineWidth = 1
            border.stroke()

            (caption as NSString).draw(in: CGRect(x: 8, y: 8, width: 124, height: 18), withAttributes: [
                .font: UIFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.8),
                .paragraphStyle: paragraphStyle(),
            ])
            let rect = CGRect(x: textArea.minX,
                              y: textArea.midY - layout.height / 2,
                              width: textArea.width, height: layout.height)
            (layout.title as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                           attributes: layout.attributes, context: nil)
        }.withRenderingMode(.alwaysOriginal)
    }

    /// まず1行で読める大きさを探し、長い名前だけ2行にする。
    /// 20ptでも全文が収まらない場合は出さない。省略や過度な縮小で別の道路名に見せないため。
    private static func layout(for title: String) -> (title: String, attributes: [NSAttributedString.Key: Any], height: CGFloat)? {
        // 「中央自動車／道へ」のように道路種別の末尾だけが次の行へ出ないよう、
        // 長い名前では「中央／自動車道へ」の区切りを先に試す。
        let suffix = ["自動車道", "高速道路", "バイパス", "スカイライン"]
            .compactMap { title.range(of: $0) }
            .first { $0.lowerBound > title.startIndex }
        let wrapped = suffix.map { String(title[..<$0.lowerBound]) + "\n" + title[$0.lowerBound...] }
        let separator = title.indices.filter { "、・／/".contains(title[$0]) }
            .min { abs(title.distance(from: title.startIndex, to: $0) - title.count / 2)
                < abs(title.distance(from: title.startIndex, to: $1) - title.count / 2) }
        let destinations = separator.map {
            String(title[...$0]) + "\n" + title[title.index(after: $0)...]
        }
        for lines in 1...2 {
            let candidates = lines == 1 ? [title] : [destinations, wrapped, title].compactMap { $0 }
            for candidate in candidates {
                let text = candidate as NSString
                for pointSize in stride(from: CGFloat(28), through: 20, by: -1) {
                    let font = UIFont.systemFont(ofSize: pointSize, weight: .bold)
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: UIColor.white,
                        .paragraphStyle: paragraphStyle(),
                    ]
                    if lines == 1, text.size(withAttributes: attributes).width > textArea.width { continue }
                    let bounds = text.boundingRect(with: CGSize(width: textArea.width, height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                   attributes: attributes, context: nil)
                    let height = ceil(bounds.height)
                    guard height <= textArea.height, height <= ceil(font.lineHeight * CGFloat(lines)),
                          bounds.width <= textArea.width else { continue }
                    return (candidate, attributes, height)
                }
            }
        }
        return nil
    }

    private static func paragraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        style.lineBreakStrategy = .standard
        return style
    }
}
