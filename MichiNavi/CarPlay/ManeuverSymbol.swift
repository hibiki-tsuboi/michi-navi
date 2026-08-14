import UIKit

/// 指示文から矢印アイコンを決める。
///
/// MapKit の `MKRoute.Step` は「右折します」のような文言しか返さず、
/// 曲がる向きを表す列挙型が公開されていない。そのため文言から推測する。
/// 経路プロバイダを Mapbox などに差し替えると構造化された maneuver type が
/// 得られるので、そのときはこのファイルごと不要になる。
enum ManeuverSymbol {
    /// 判定は上から順に行う。長い語（「斜め右」）を短い語（「右」）より先に置く。
    private static let rules: [(keywords: [String], symbol: String)] = [
        (["Uターン", "U ターン", "u-turn", "U-turn"], "arrow.uturn.down"),
        (["高速", "有料道路", "ランプ", "ramp", "highway", "freeway"], "arrow.triangle.merge"),
        (["合流", "merge"], "arrow.merge"),
        (["ロータリー", "環状", "roundabout", "rotary"], "arrow.triangle.turn.up.right.circle"),
        (["斜め右", "右斜め", "slight right", "bear right"], "arrow.up.right"),
        (["斜め左", "左斜め", "slight left", "bear left"], "arrow.up.left"),
        (["右方向", "右折", "右に", "右へ", "turn right", "right"], "arrow.turn.up.right"),
        (["左方向", "左折", "左に", "左へ", "turn left", "left"], "arrow.turn.up.left"),
        (["到着", "目的地", "arrive", "destination"], "mappin.and.ellipse"),
        (["直進", "そのまま", "continue", "straight", "head"], "arrow.up"),
    ]

    static func image(for instruction: String) -> UIImage? {
        let name = rules.first { rule in
            rule.keywords.contains { instruction.localizedCaseInsensitiveContains($0) }
        }?.symbol ?? "arrow.up"

        // CarPlay の maneuver アイコンは 1 色で描かれるので template を渡す。
        let configuration = UIImage.SymbolConfiguration(pointSize: 40, weight: .semibold)
        return UIImage(systemName: name, withConfiguration: configuration)?
            .withRenderingMode(.alwaysTemplate)
    }
}
