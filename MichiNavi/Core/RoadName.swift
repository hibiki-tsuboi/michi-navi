import Foundation

/// 指示文から「曲がった先の道路名」を取り出す。「国道156号を右方向」の「国道156号」、
/// 「市役所前で左方向 百万石通り」の「百万石通り」にあたる部分。
///
/// 行き先は `CPManeuver.roadFollowingManeuverVariants` ひとつで、**車のメーター・HUD が
/// 「いま曲がって入る道はどこか」を出すのに使う**。MapKit の `MKRoute.Step` は道路名を
/// 別のプロパティで返さないので、指示文から拾うしかない（`ManeuverDirection` や
/// `RoadNumber` と同じ事情）。
///
/// **取りこぼす側に倒す。** 落ちても車が道路名を出さないだけだが、関係のない語を道路名
/// として送ると HUD に嘘が出る。そのため拾うのは「道路名だと分かる語尾」で終わる塊だけで、
/// しかも**ひらがなは名前の一部として認めない**（下記）。道路名を持たない指示文
/// （「突き当たりを右折」など）は普通にあるので、出ないことは異常ではない。
///
/// **この表は訳さない。日英を並べる。** `ManeuverDirection` と同じで、端末の言語で入力
/// そのものが変わるため（`RoadNumber` だけは理由が違う——あちらは標識の絵が国ごとに
/// 違うので日本語の指示文だけを見る）。
enum RoadName {
    /// 道路名の語尾。**長いものを先に置く**（「自動車道」は「道路」より先）。
    ///
    /// **「線」ではなく「号線」**。「環状八号線」のように漢数字で書かれる道を拾うために
    /// 要るが、「線」だけにすると「右車線を走行して首都高速入口へ」の**「右車線」が
    /// 道路名になる**（実際にそうなった）。算用数字の付く道は `RoadNumber` が先に拾う。
    private static let suffixes = [
        "自動車道", "高速道路", "バイパス", "スカイライン", "街道", "号線", "通り", "道路",
    ]

    /// 語尾の手前に取れる最大の文字数。長い塊をそのまま名前にしないための上限。
    private static let maximumLength = 12

    /// 語尾の規則には当てはまるが、道の名前ではないもの。
    ///
    /// 「大通り」が入っているのは、**ひらがなで切れた名前の残り**だから
    /// （「みなとみらい大通り」→「大通り」）。名前の一部しか送れないくらいなら送らない。
    private static let excluded = ["有料道路", "一般道路", "高速道路", "大通り"]

    /// 指示文に出てくる道路名。見つからなければ nil。
    ///
    /// 番号を持つ道（`RoadNumber`）が先。「国道156号」は番号そのものが名前として通って
    /// いるうえ、表記のゆれが無い。
    static func first(in instruction: String) -> String? {
        if let numbered = RoadNumber.first(in: instruction) {
            return String(instruction[numbered.range])
        }
        if let japanese = japaneseName(in: instruction) { return japanese }
        return englishName(in: instruction)
    }

    /// 語尾で終わる塊を探し、名前に使える文字が続くかぎり前へ伸ばす。
    private static func japaneseName(in instruction: String) -> String? {
        for suffix in suffixes {
            guard let found = instruction.range(of: suffix) else { continue }

            var start = found.lowerBound
            var length = 0
            while start > instruction.startIndex, length < maximumLength {
                let previous = instruction.index(before: start)
                guard isNamePart(instruction[previous]) else { break }
                start = previous
                length += 1
            }
            // 語尾だけで名前を持たないもの（「高速道路に入る」の「道路」）は捨てる。
            guard length > 0 else { continue }

            let name = String(instruction[start ..< found.upperBound])
            guard !excluded.contains(name) else { continue }
            return name
        }
        return nil
    }

    /// 道路名の一部として認める文字。**ひらがなを外してある。**
    ///
    /// 日本語の指示文は名前と動作を助詞や活用でつなぐ（「交差点を右折して環八通り」）ので、
    /// 区切りの語を数え上げる形にすると必ず漏れが出て、「右折して環八通り」のような
    /// 塊を道路名として車へ送ることになる。**名前に使える文字だけを通す**ほうが安全側。
    /// 代わりに「みなとみらい大通り」のようなひらがなを含む名前は「大通り」で切れて
    /// 落ちる（`maximumLength` ではなくここで落ちる）が、嘘を出すよりはよい。
    private static func isNamePart(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else { return false }
        return switch scalar.value {
        case 0x4E00 ... 0x9FFF, 0x3005: true            // 漢字と々
        case 0x30A0 ... 0x30FF: true                    // カタカナ（長音符を含む）
        case 0x0030 ... 0x0039, 0xFF10 ... 0xFF19: true // 数字（半角・全角）
        case 0x0041 ... 0x005A, 0x0061 ... 0x007A: true // 英字
        default: false
        }
    }

    /// 英語の指示文は「onto <道路名>」「on <道路名>」と前置詞が挟まるので、語尾で
    /// 見分ける必要がない。**長い語を先に見る**のは日本語側と同じ理由。
    private static func englishName(in instruction: String) -> String? {
        for preposition in [" onto ", " on "] {
            guard let found = instruction.range(of: preposition,
                                                options: [.caseInsensitive]) else { continue }
            let tail = instruction[found.upperBound...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " .,"))
            guard !tail.isEmpty, tail.count <= 40 else { continue }
            return tail
        }
        return nil
    }
}
