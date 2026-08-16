import Foundation

/// 指示文から道路番号を取り出す。「国道156号を右方向」の「国道156号」にあたる部分。
///
/// 日本の運転者は道路を**番号で追う**。案内文の中に埋もれている番号を標識の形にして
/// 差し込むと、走行中に一瞥で拾える（`RoadShieldImage` が描き、`CPManeuver` の
/// `attributedInstructionVariants` に載る）。
///
/// **この表は訳さない。ただし理由がほかの文言マッチと違う。**
/// `ManeuverDirection` や `VoiceCommand` は「端末の言語で入力が変わる」から日英を並べるが、
/// こちらは**標識そのものが国ごとに違う**。日本の国道は青い逆三角（おにぎり）で、
/// 同じ形を US Route に付けたら誤りになる。日本語の指示文だけを拾い、英語では
/// 標識を出さずに元の文をそのまま見せる。
enum RoadNumber: Equatable {
    /// 国道。青い逆三角。
    case national(Int)
    /// 都道府県道（県道・都道・府道・道道）。青い六角形。
    case prefectural(Int)
    /// 番号の付いた都市高速（首都高速・阪神高速など）。緑の角丸。
    case expressway(Int)

    var number: Int {
        switch self {
        case let .national(number), let .prefectural(number), let .expressway(number): number
        }
    }

    /// 上から順に試す。**長い語を先に置く**という規則はここでも同じで、
    /// 「首都高速3号」を「高速」より先に見ないと都市高速が拾えない。
    private static let patterns: [(pattern: String, make: (Int) -> RoadNumber)] = [
        (#"(?:首都|阪神|名古屋|福岡|北九州|広島|京都)高速(\d{1,4})号"#, RoadNumber.expressway),
        (#"国道(\d{1,4})号"#, RoadNumber.national),
        (#"[県都府道]道(\d{1,4})号"#, RoadNumber.prefectural),
    ]

    /// 指示文の中で**最初に**見つかった道路番号と、その範囲。
    ///
    /// 範囲まで返すのは、呼ぶ側が**その部分を標識の画像に差し替える**ため。
    /// 見つからなければ nil を返し、指示文はそのまま使われる。
    static func first(in instruction: String) -> (road: RoadNumber, range: Range<String.Index>)? {
        var best: (road: RoadNumber, range: Range<String.Index>)?

        for (pattern, make) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let text = instruction as NSString
            guard let match = regex.firstMatch(in: instruction,
                                               range: NSRange(location: 0, length: text.length)),
                  match.numberOfRanges >= 2,
                  let number = Int(text.substring(with: match.range(at: 1))),
                  let range = Range(match.range, in: instruction) else { continue }

            // 複数の型に当たったときは、文の先に出てくるほうを採る。
            if let current = best, current.range.lowerBound <= range.lowerBound { continue }
            best = (make(number), range)
        }
        return best
    }
}
