import CarPlay
import UIKit

/// 曲がる向き（`ManeuverDirection`）を、画面と車に見せる形へ読み替える。
///
/// 行き先は 2 か所:
///
///   1. CarPlay の案内カードに出す矢印アイコン
///   2. `CPManeuver.maneuverType`。**車のメーターや HUD へ送られる**（ガイド p.56）。
///      デジタルメーターを持たない車でも、この値だけは受け取って表示できる。
///
/// **推測そのものはここに無い**。指示文の読み取りは `ManeuverDirection`（`Core/`）にある。
/// 向きは表示以外にも使う（候補ルートの右折の数を数えるなど）ので、CarPlay の型と
/// 一緒にしておけない。
struct ManeuverKind {
    let symbolName: String
    let type: CPManeuverType

    static func inferred(from instruction: String) -> ManeuverKind {
        kind(for: ManeuverDirection.inferred(from: instruction))
    }

    /// どの規則にも当てはまらなかったときは、矢印を直進のまま出したいので
    /// 型も「いまの道をそのまま進む」に寄せて、画面と HUD の食い違いを避ける。
    private static func kind(for direction: ManeuverDirection) -> ManeuverKind {
        switch direction {
        case .uTurn: ManeuverKind(symbolName: "arrow.uturn.down", type: .uTurn)
        case .roundabout: ManeuverKind(symbolName: "arrow.triangle.turn.up.right.circle", type: .enterRoundabout)
        case .offRamp: ManeuverKind(symbolName: "arrow.triangle.turn.up.right", type: .offRamp)
        case .onRamp: ManeuverKind(symbolName: "arrow.triangle.merge", type: .onRamp)
        case .merge: ManeuverKind(symbolName: "arrow.merge", type: .onRamp)
        case .slightRight: ManeuverKind(symbolName: "arrow.up.right", type: .slightRightTurn)
        case .slightLeft: ManeuverKind(symbolName: "arrow.up.left", type: .slightLeftTurn)
        case .right: ManeuverKind(symbolName: "arrow.turn.up.right", type: .rightTurn)
        case .left: ManeuverKind(symbolName: "arrow.turn.up.left", type: .leftTurn)
        case .arrive: ManeuverKind(symbolName: "mappin.and.ellipse", type: .arriveAtDestination)
        case .depart: ManeuverKind(symbolName: "arrow.up", type: .startRoute)
        case .straight: ManeuverKind(symbolName: "arrow.up", type: .straightAhead)
        case .unknown: ManeuverKind(symbolName: "arrow.up", type: .followRoad)
        }
    }

    var image: UIImage? {
        // CarPlay の maneuver アイコンは 1 色で描かれるので template を渡す。
        let configuration = UIImage.SymbolConfiguration(pointSize: 40, weight: .semibold)
        return UIImage(systemName: symbolName, withConfiguration: configuration)?
            .withRenderingMode(.alwaysTemplate)
    }
}
