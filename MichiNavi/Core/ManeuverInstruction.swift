import Foundation

/// 案内文の表示候補。高速では「出口」だけに縮めると標識と照合できなくなるため、
/// 元の文にある方面・JCT/IC名・出口番号を、どの候補にも残す。
struct ManeuverInstruction {
    struct Signpost {
        let title: String
        let caption: String
    }

    let original: String
    let direction: ManeuverDirection
    let side: ManeuverDirection.Side?
    let variants: [String]
    let compactVariants: [String]
    let signpost: Signpost?
    let exitLabel: String?

    init(_ instruction: String) {
        original = instruction
        direction = ManeuverDirection.inferred(from: instruction)
        side = ManeuverDirection.side(in: instruction)

        let preservesSignpost = [.offRamp, .onRamp, .merge, .keepLeft, .keepRight].contains(direction)
            || ManeuverDirection.hasHighwayContext(in: instruction)
            || instruction.contains("方面")
            || instruction.range(of: #"\b(?:towards?|signs for)\b"#,
                                 options: [.regularExpression, .caseInsensitive]) != nil
        let compact = preservesSignpost ? Self.compact(instruction) : direction.shortInstruction
        variants = Self.unique([instruction, compact].compactMap { $0 })
        compactVariants = Self.unique([compact, instruction].compactMap { $0 })

        let junction = Self.capture(#"^\s*(.+?(?:JCT|IC|ジャンクション|インターチェンジ|ランプ))で"#, in: instruction)
        let numberedExit = Self.capture(#"\b(exit\s+[0-9]+[a-z]?(?:-[0-9]+)?)\b"#, in: instruction)
        exitLabel = direction == .offRamp ? numberedExit ?? junction : nil
        if preservesSignpost, let destination = Self.destination(in: instruction) {
            signpost = Signpost(title: destination, caption: String(localized: "方面"))
        } else if preservesSignpost, let location = junction ?? numberedExit {
            let caption: String = switch direction {
            case .offRamp: String(localized: "出口")
            case .onRamp: String(localized: "入口")
            default: String(localized: "分岐")
            }
            signpost = Signpost(title: location, caption: caption)
        } else {
            signpost = nil
        }
    }

    /// 名前は切らず、操作の冗長な言い回しだけ縮める。元の案内文と同じ言語で保つ。
    private static func compact(_ instruction: String) -> String {
        let replacements = [
            ("ジャンクションで", "JCTで"), ("インターチェンジで", "ICで"),
            ("を走行して", " "), ("を走行", " "),
            ("方向に進みます", "方向"), ("へ進みます", "へ"),
        ]
        return replacements.reduce(instruction) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 「方面」の直前にある名前を、そのまま強調する。地図にない都市名・出口番号は補わない。
    private static func destination(in instruction: String) -> String? {
        if let bound = instruction.range(of: "方面") {
            let prefix = String(instruction[..<bound.lowerBound])
            // 日本語の名前にはひらがなもある。文字種で削らず、指示文の区切りから読む。
            let separators = ["を走行して", "を走行", "分岐して",
                              "方向に進んで", "方向", "左折して", "右折して", "向かって"]
            let start = separators.compactMap { prefix.range(of: $0, options: .backwards)?.upperBound }
                .max() ?? prefix.startIndex
            // 「霞が関、 中央道」の空白を区切りにすると先頭の地名が落ちる。
            let name = Self.capture(#"[（(]([^（）()]*)$"#, in: prefix)
                ?? String(prefix[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
            // 区切りを読めなかった文を、地名として強調しない。全文は通常の案内に残る。
            guard !name.isEmpty,
                  name.range(of: #"を|走行|車線|直進|左折|右折|分岐|(?:JCT|IC|ランプ)で"#,
                             options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
            return name
        }
        guard let name = capture(#"\b(?:towards?|follow signs for)\s+(.+?)[.]?$"#, in: instruction),
              name.range(of: #"\b(?:turn|keep|merge|take|then)\b"#,
                         options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        return name
    }

    private static func capture(_ pattern: String, in instruction: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: instruction, range: NSRange(instruction.startIndex..., in: instruction)),
              let range = Range(match.range(at: 1), in: instruction) else { return nil }
        let value = instruction[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func unique(_ variants: [String]) -> [String] {
        variants.reduce(into: []) { result, variant in
            if !result.contains(variant) { result.append(variant) }
        }
    }
}
