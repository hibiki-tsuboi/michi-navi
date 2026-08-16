import CoreLocation
import Foundation
import MapKit

/// 経路の先から寄り道先をひとつ選んで出す。
///
/// カーナビは「早く着く」ことしか手伝わないが、移動そのものが目的の運転もある。
/// 探し方は決まっていて（`SearchService`）、足りないのは**選ぶ理由**なので、
/// そこを乱数に任せる。
///
/// 出すのは 1 件だけ。候補を並べると結局いつもの選び方に戻ってしまうし、
/// 運転中に一覧を読ませたくない。
enum DetourSuggester {
    /// 寄り道に向くカテゴリ。
    ///
    /// 用事で寄る場所（ガソリン・駐車場・病院）は入れない。あれは必要になったときに
    /// 名指しで探すもので、勧められて嬉しいものではない。
    private static let categories: [(title: String, points: [MKPointOfInterestCategory])] = [
        (String(localized: "カフェ"), [.cafe]),
        (String(localized: "パン屋"), [.bakery]),
        (String(localized: "公園"), [.park]),
        (String(localized: "景色"), [.beach, .nationalPark]),
        (String(localized: "美術館・博物館"), [.museum]),
        (String(localized: "水族館・動物園"), [.aquarium, .zoo]),
        (String(localized: "お城・史跡"), [.castle, .fortress, .nationalMonument]),
        (String(localized: "市場"), [.foodMarket]),
        (String(localized: "ワイナリー・醸造所"), [.winery, .brewery]),
        (String(localized: "温泉・スパ"), [.spa]),
    ]

    struct Suggestion {
        let category: String
        let place: Place
    }

    /// 案内中なら経路の先、そうでなければ現在地のまわりから 1 件選ぶ。
    ///
    /// 上位から選ばずに散らすのは、いちばん近い店を出すだけなら普通の検索と変わらないから。
    /// ただし遠すぎても寄れないので、手前の何件かに限る。
    static func suggest(near coordinate: CLLocationCoordinate2D,
                        along route: NavRoute?,
                        fromStepIndex stepIndex: Int) async throws -> Suggestion? {
        guard let category = categories.randomElement() else { return nil }

        let places: [Place]
        if let route {
            places = try await SearchService.shared.alongRoute(
                pointsOfInterest: category.points,
                coordinates: route.remainingCoordinates(from: stepIndex))
        } else {
            places = try await SearchService.shared.nearby(pointsOfInterest: category.points,
                                                           around: coordinate)
        }

        guard let place = places.prefix(candidatePool).randomElement() else { return nil }
        return Suggestion(category: category.title, place: place)
    }

    /// この件数までの中から選ぶ。増やすと「行けなくはないが遠い」ものが混ざる。
    private static let candidatePool = 5
}
