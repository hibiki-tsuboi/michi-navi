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

    init(_ instruction: ManeuverInstruction) {
        let appearance = Self.appearance(for: instruction.direction, side: instruction.side)
        symbolName = appearance.symbolName
        type = appearance.type
    }

    /// どの規則にも当てはまらなかったときは、矢印を直進のまま出したいので
    /// 型も「いまの道をそのまま進む」に寄せて、画面と HUD の食い違いを避ける。
    private static func appearance(for direction: ManeuverDirection,
                                   side: ManeuverDirection.Side?) -> (symbolName: String, type: CPManeuverType) {
        switch direction {
        case .uTurn: ("arrow.uturn.down", .uTurn)
        case .roundabout: ("arrow.triangle.turn.up.right.circle", .enterRoundabout)
        case .offRamp:
            // 向き不明の出口に右矢印を付けない。分かる左右は車のメーターにも同じ意味で渡す。
            switch side {
            case .left: ("arrow.up.left", .highwayOffRampLeft)
            case .right: ("arrow.up.right", .highwayOffRampRight)
            case nil: ("road.lanes", .offRamp)
            }
        case .onRamp:
            switch side {
            case .left: ("arrow.up.left", .onRamp)
            case .right: ("arrow.up.right", .onRamp)
            case nil: ("road.lanes", .onRamp)
            }
        case .merge: ("arrow.merge", .onRamp)
        // 車線の指示は矢印ではなく道路の記号にする。**斜め右折と見分けが付かないと
        // 分岐の手前でハンドルを切られる。** 型のほうも `.keepRight` があるので、
        // 車のメーター・HUD には正確な意味で届く。
        case .keepRight: ("road.lanes.curved.right", .keepRight)
        case .keepLeft: ("road.lanes.curved.left", .keepLeft)
        case .slightRight: ("arrow.up.right", .slightRightTurn)
        case .slightLeft: ("arrow.up.left", .slightLeftTurn)
        case .right: ("arrow.turn.up.right", .rightTurn)
        case .left: ("arrow.turn.up.left", .leftTurn)
        case .arrive: ("mappin.and.ellipse", .arriveAtDestination)
        case .depart: ("arrow.up", .startRoute)
        case .straight: ("arrow.up", .straightAhead)
        case .unknown: ("arrow.up", .followRoad)
        }
    }

    var image: UIImage? {
        // CarPlay の maneuver アイコンは 1 色で描かれるので template を渡す。
        let configuration = UIImage.SymbolConfiguration(pointSize: 40, weight: .semibold)
        return UIImage(systemName: symbolName, withConfiguration: configuration)?
            .withRenderingMode(.alwaysTemplate)
    }
}
