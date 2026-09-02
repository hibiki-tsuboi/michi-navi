import CoreLocation
import Foundation

/// 案内を始める前に、選んだ経路で支度や選択が変わる情報だけをまとめる。
///
/// 距離・所要・到着予定はルートの見出しにすでに出ている。ここではそれを繰り返さず、
/// このアプリが持つ走行履歴、候補どうしの比較、経路の指示、太陽の位置、MapKit の注意を
/// 1 か所へ集める。どれもルート計算が終わった時点で手元にあるため、新しい問い合わせはしない。
struct DriveBrief: Equatable {
    struct Item: Equatable {
        enum Kind: Equatable {
            case novelty
            case comparison
            case turns
            case sunlight
            case advisory
            case waypoint
        }

        let kind: Kind
        let title: String
        let detail: String
        let symbolName: String
    }

    let newRoadPercentage: Int?
    let newRoadDistance: CLLocationDistance?
    let comparisonTags: [String]
    let rightTurns: Int
    let leftTurns: Int
    let glare: SunGlareAdvisor.Glare?
    let advisories: [String]
    let waypointNames: [String]

    /// 候補一覧に入る短い要約。詳細画面より狭いので、右左折の数と立ち寄り先は落とす。
    var highlights: [String] {
        var result: [String] = []
        if let newRoadPercentage {
            result.append(RouteNovelty.label(for: newRoadPercentage))
        }
        result.append(contentsOf: comparisonTags)
        if let glare {
            result.append(glare.briefMessage)
        }
        result.append(contentsOf: advisories)
        return result
    }

    /// iPhone と CarPlay の詳細画面に出す項目。
    ///
    /// 注意と太陽を先頭にする。CarPlay の情報テンプレートは最大 10 件なので、支度や運転が
    /// 変わる項目を、楽しさや経路の数字より先に残す。
    var items: [Item] {
        var result: [Item] = advisories.map {
            Item(kind: .advisory,
                 title: String(localized: "経路上の注意"),
                 detail: $0,
                 symbolName: "exclamationmark.triangle.fill")
        }

        if let glare {
            let title = switch glare.sun {
            case .morning: String(localized: "朝日への備え")
            case .evening: String(localized: "西日への備え")
            }
            result.append(Item(kind: .sunlight,
                               title: title,
                               detail: String(localized: "\(glare.message)。\(glare.detail)"),
                               symbolName: glare.symbolName))
        }

        if let newRoadPercentage, let newRoadDistance {
            result.append(Item(
                kind: .novelty,
                title: String(localized: "初めての道"),
                detail: String.localizedStringWithFormat(
                    String(localized: "全体の %lld%%・約 %@"),
                    Int64(newRoadPercentage),
                    Formatters.distanceText(newRoadDistance)
                ),
                symbolName: "sparkles"
            ))
        }

        if !comparisonTags.isEmpty {
            result.append(Item(kind: .comparison,
                               title: String(localized: "候補との違い"),
                               detail: comparisonTags.joined(separator: String(localized: "・")),
                               symbolName: "arrow.triangle.branch"))
        }

        if rightTurns > 0 || leftTurns > 0 {
            result.append(Item(
                kind: .turns,
                title: String(localized: "曲がる回数"),
                detail: String.localizedStringWithFormat(
                    String(localized: "右折 %1$lld回・左折 %2$lld回"),
                    Int64(rightTurns),
                    Int64(leftTurns)
                ),
                symbolName: "arrow.turn.up.right"
            ))
        }

        result.append(contentsOf: waypointNames.map {
            Item(kind: .waypoint,
                 title: String(localized: "立ち寄り先"),
                 detail: $0,
                 symbolName: "mappin.and.ellipse")
        })
        return result
    }

    static func make(for route: NavRoute,
                     comparisonTags: [String],
                     departure: Date) -> DriveBrief {
        let directions = route.steps.map { ManeuverDirection.inferred(from: $0.instruction) }
        let rightTurns = directions.count(where: \.isRightTurn)
        let leftTurns = directions.count { direction in
            direction == .left || direction == .slightLeft
        }
        let percentage = route.newRoadPercentage

        return DriveBrief(
            newRoadPercentage: percentage,
            newRoadDistance: percentage.map { route.distance * Double($0) / 100 },
            comparisonTags: comparisonTags,
            rightTurns: rightTurns,
            leftTurns: leftTurns,
            glare: SunGlareAdvisor.find(on: route, departure: departure),
            advisories: route.advisoryNotices,
            waypointNames: route.displayedWaypoints.map(\.name)
        )
    }
}
