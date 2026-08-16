import Foundation

/// 指示文から「どう曲がるか」を推測する。
///
/// MapKit の `MKRoute.Step` は「右折します」のような文言しか返さず、曲がる向きを表す
/// 列挙型が公開されていない。そのため文言から推測するしかない。
///
/// **この推測を CarPlay の型から切り離してある**のは、向きを使うのが表示だけでは
/// ないため。候補ルートの右折の数を数える（`RouteCharacter`）のは案内の見た目とは
/// 無関係な計算で、そちらのために CarPlay を `Core/` へ持ち込みたくない。
/// 見た目への読み替えは `ManeuverKind` が持つ。
///
/// 経路プロバイダを Mapbox などに差し替えると構造化された maneuver type が
/// 得られるので、そのときはこのファイルごと不要になる。
enum ManeuverDirection {
    case uTurn
    case roundabout
    case offRamp
    case onRamp
    case merge
    /// 右車線を走行（分岐の手前で寄せる）。曲がるのではなく、車線を選ぶ指示。
    case keepRight
    case keepLeft
    case slightRight
    case slightLeft
    case right
    case left
    case arrive
    case depart
    case straight
    /// どの規則にも当てはまらなかった。
    case unknown

    /// 判定は上から順に行う。規則は 2 つある。
    ///
    /// 1. **長い語を短い語より先に置く。** 「斜め右」は「右」より先、「ロータリー」は
    ///    「出口」より先でなければならない。後者を逆にすると「2 番目の出口で出る」が
    ///    高速の出口として扱われる。
    /// 2. **道路名に現れる語を入れない。** 「環状」を入れていたときは「環状1号を右方向」が
    ///    ロータリー扱いになり、アイコンだけでなく `CPManeuver.maneuverType` として
    ///    `.enterRoundabout` が車のメーター・HUD へ送られていた（2026-08-16 に横浜で実測）。
    ///    日本の道路名には「環状八号線」「内環状」のように普通に入る。**取りこぼすほうが
    ///    まだ良い**（`VoiceCommand` の fallback と同じ判断）ので、交差点だと分かる形に絞る。
    private static let rules: [(keywords: [String], direction: ManeuverDirection)] = [
        (["Uターン", "U ターン", "u-turn", "U-turn"], .uTurn),
        (["ロータリー", "環状交差点", "roundabout", "rotary"], .roundabout),
        (["出口", "降り", "off ramp", "off-ramp", "exit"], .offRamp),
        (["高速", "有料道路", "ランプ", "ramp", "highway", "freeway"], .onRamp),
        (["合流", "merge"], .merge),
        // **車線の指示は曲がる指示より先。** 「右車線を走行して環八通りへ」を右折と
        // 読むと、分岐の手前でハンドルを切らせることになる。ただし高速の入口・出口より
        // 後ろに置く（「池尻ランプで右車線を走行 首都高速入口へ」は入口が主）。
        (["右車線", "keep right"], .keepRight),
        (["左車線", "keep left"], .keepLeft),
        (["斜め右", "右斜め", "slight right", "bear right"], .slightRight),
        (["斜め左", "左斜め", "slight left", "bear left"], .slightLeft),
        (["右方向", "右折", "右に", "右へ", "turn right", "right"], .right),
        (["左方向", "左折", "左に", "左へ", "turn left", "left"], .left),
        // 「駐車を準備」は MapKit が車を降ろす地点に置く指示で、徒歩の step を落として
        // いる（`MKRoute.drivingSteps`）いま、**これが経路の最後の指示になる**。
        (["到着", "目的地", "駐車", "arrive", "destination", "park"], .arrive),
        (["出発", "depart"], .depart),
        (["直進", "そのまま", "continue", "straight", "head"], .straight),
    ]

    static func inferred(from instruction: String) -> ManeuverDirection {
        rules.first { rule in
            rule.keywords.contains { instruction.localizedCaseInsensitiveContains($0) }
        }?.direction ?? .unknown
    }

    /// 一言で言い切った指示。**狭い画面のための短縮形**。
    ///
    /// MapKit の指示文は「市役所前で左方向 百万石通り」のように地名と道路名を抱えていて、
    /// Dashboard や通知バナーの幅には入らない。CarPlay は渡した候補の先頭から**入るものを
    /// 選ぶ**ので、長い文が入らないときの落とし先を用意しておく。地名と道路名は落ちるが、
    /// **曲がる向きだけは必ず残る**。
    ///
    /// **上の `rules` と役割が逆なので混同しないこと。** あちらは MapKit から来る文を
    /// 読むための表なので訳さず日英を並べる。こちらは利用者に見せる文なので、
    /// 端末の言語に訳す。
    var shortInstruction: String? {
        switch self {
        case .uTurn: String(localized: "Uターン")
        case .roundabout: String(localized: "ロータリー")
        case .offRamp: String(localized: "出口")
        case .onRamp: String(localized: "入口")
        case .merge: String(localized: "合流")
        case .keepRight: String(localized: "右車線")
        case .keepLeft: String(localized: "左車線")
        case .slightRight: String(localized: "斜め右")
        case .slightLeft: String(localized: "斜め左")
        case .right: String(localized: "右折")
        case .left: String(localized: "左折")
        case .arrive: String(localized: "到着")
        case .depart: String(localized: "出発")
        case .straight: String(localized: "直進")
        // 向きが分からないものを縮めても、意味の無い言葉しか作れない。
        // 渡さなければ CarPlay が元の指示文へ落ちる。
        case .unknown: nil
        }
    }

    /// 交差点で右へ向く指示か。日本のような左側通行では、これが多いほど
    /// 対向車を待つ場面が増える。
    var isRightTurn: Bool { self == .right || self == .slightRight }

    /// 高速・有料道路へ入る指示か。
    var entersHighway: Bool { self == .onRamp }
}
