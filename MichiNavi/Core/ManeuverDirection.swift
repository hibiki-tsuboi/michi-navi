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
    case slightRight
    case slightLeft
    case right
    case left
    case arrive
    case depart
    case straight
    /// どの規則にも当てはまらなかった。
    case unknown

    /// 判定は上から順に行う。**長い語を短い語より先に置く**のが唯一の規則で、
    /// 「斜め右」は「右」より先、「ロータリー」は「出口」より先でなければならない。
    /// 後者を逆にすると「2 番目の出口で出る」が高速の出口として扱われる。
    private static let rules: [(keywords: [String], direction: ManeuverDirection)] = [
        (["Uターン", "U ターン", "u-turn", "U-turn"], .uTurn),
        (["ロータリー", "環状", "roundabout", "rotary"], .roundabout),
        (["出口", "降り", "off ramp", "off-ramp", "exit"], .offRamp),
        (["高速", "有料道路", "ランプ", "ramp", "highway", "freeway"], .onRamp),
        (["合流", "merge"], .merge),
        (["斜め右", "右斜め", "slight right", "bear right"], .slightRight),
        (["斜め左", "左斜め", "slight left", "bear left"], .slightLeft),
        (["右方向", "右折", "右に", "右へ", "turn right", "right"], .right),
        (["左方向", "左折", "左に", "左へ", "turn left", "left"], .left),
        (["到着", "目的地", "arrive", "destination"], .arrive),
        (["出発", "depart"], .depart),
        (["直進", "そのまま", "continue", "straight", "head"], .straight),
    ]

    static func inferred(from instruction: String) -> ManeuverDirection {
        rules.first { rule in
            rule.keywords.contains { instruction.localizedCaseInsensitiveContains($0) }
        }?.direction ?? .unknown
    }

    /// 交差点で右へ向く指示か。日本のような左側通行では、これが多いほど
    /// 対向車を待つ場面が増える。
    var isRightTurn: Bool { self == .right || self == .slightRight }

    /// 高速・有料道路へ入る指示か。
    var entersHighway: Bool { self == .onRamp }
}
