import CarPlay
import UIKit

/// 指示文から「どう曲がるか」を推測する。
///
/// MapKit の `MKRoute.Step` は「右折します」のような文言しか返さず、
/// 曲がる向きを表す列挙型が公開されていない。そのため文言から推測する。
/// 出てきた結果は 2 か所で使う:
///
///   1. CarPlay の案内カードに出す矢印アイコン
///   2. `CPManeuver.maneuverType`。**車のメーターや HUD へ送られる**（ガイド p.56）。
///      デジタルメーターを持たない車でも、この値だけは受け取って表示できる。
///
/// 経路プロバイダを Mapbox などに差し替えると構造化された maneuver type が
/// 得られるので、そのときはこのファイルごと不要になる。
struct ManeuverKind {
    let symbolName: String
    let type: CPManeuverType

    /// どの規則にも当てはまらなかったとき。矢印は直進のまま出したいので、
    /// 型も「いまの道をそのまま進む」に寄せて、画面と HUD の食い違いを避ける。
    private static let fallback = ManeuverKind(symbolName: "arrow.up", type: .followRoad)

    /// 判定は上から順に行う。**長い語を短い語より先に置く**のが唯一の規則で、
    /// 「斜め右」は「右」より先、「ロータリー」は「出口」より先でなければならない。
    /// 後者を逆にすると「2 番目の出口で出る」が高速の出口として扱われる。
    private static let rules: [(keywords: [String], kind: ManeuverKind)] = [
        (["Uターン", "U ターン", "u-turn", "U-turn"],
         ManeuverKind(symbolName: "arrow.uturn.down", type: .uTurn)),
        (["ロータリー", "環状", "roundabout", "rotary"],
         ManeuverKind(symbolName: "arrow.triangle.turn.up.right.circle", type: .enterRoundabout)),
        (["出口", "降り", "off ramp", "off-ramp", "exit"],
         ManeuverKind(symbolName: "arrow.triangle.turn.up.right", type: .offRamp)),
        (["高速", "有料道路", "ランプ", "ramp", "highway", "freeway"],
         ManeuverKind(symbolName: "arrow.triangle.merge", type: .onRamp)),
        (["合流", "merge"],
         ManeuverKind(symbolName: "arrow.merge", type: .onRamp)),
        (["斜め右", "右斜め", "slight right", "bear right"],
         ManeuverKind(symbolName: "arrow.up.right", type: .slightRightTurn)),
        (["斜め左", "左斜め", "slight left", "bear left"],
         ManeuverKind(symbolName: "arrow.up.left", type: .slightLeftTurn)),
        (["右方向", "右折", "右に", "右へ", "turn right", "right"],
         ManeuverKind(symbolName: "arrow.turn.up.right", type: .rightTurn)),
        (["左方向", "左折", "左に", "左へ", "turn left", "left"],
         ManeuverKind(symbolName: "arrow.turn.up.left", type: .leftTurn)),
        (["到着", "目的地", "arrive", "destination"],
         ManeuverKind(symbolName: "mappin.and.ellipse", type: .arriveAtDestination)),
        (["出発", "depart"],
         ManeuverKind(symbolName: "arrow.up", type: .startRoute)),
        (["直進", "そのまま", "continue", "straight", "head"],
         ManeuverKind(symbolName: "arrow.up", type: .straightAhead)),
    ]

    static func inferred(from instruction: String) -> ManeuverKind {
        rules.first { rule in
            rule.keywords.contains { instruction.localizedCaseInsensitiveContains($0) }
        }?.kind ?? fallback
    }

    var image: UIImage? {
        // CarPlay の maneuver アイコンは 1 色で描かれるので template を渡す。
        let configuration = UIImage.SymbolConfiguration(pointSize: 40, weight: .semibold)
        return UIImage(systemName: symbolName, withConfiguration: configuration)?
            .withRenderingMode(.alwaysTemplate)
    }
}
