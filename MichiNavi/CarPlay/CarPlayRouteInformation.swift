import CarPlay
import Foundation

/// ルート提示中に「この経路の中身」を見せる画面（`CPInformationTemplate`）。
///
/// **候補一覧に出せない情報を出すためにある。** CarPlay の候補一覧は名前と距離・時間しか
/// 並べられないので、**どれが有料か**が選ぶ時点で分からない。MapKit は経路ごとに
/// `advisoryNotices` を返していて（実測: 渋谷→成城で候補 1・3 が「通行料の支払いが
/// 必要です」、候補 2 は無し）、そこが実際の決め手になる。
///
/// **走行中には出さない。** 開けるのはルート提示のあいだだけで、案内が始まったら
/// 入口ごと消える。停まっているうちに見て決めるための画面。
///
/// **営業時間は出せない。** `MKMapItem` が持っているのは identifier / location / address /
/// name / phoneNumber / url / timeZone だけで、営業時間を返す口が無い。外部依存を足さない
/// 限り埋まらないので、最初から項目に入れていない。
enum CarPlayRouteInformation {
    /// `CPInformationTemplate` に載る上限（ヘッダに明記。超えたぶんは黙って切られる）。
    private static let maximumItems = 10

    static func template(for route: NavRoute, onStart: @escaping () -> Void) -> CPInformationTemplate {
        let start = CPTextButton(title: String(localized: "この経路で開始"), textStyle: .confirm) { _ in
            onStart()
        }
        return CPInformationTemplate(title: String(localized: "経路の詳細"),
                                     layout: .leading,
                                     items: items(for: route),
                                     actions: [start])
    }

    /// **決め手になる順に並べる。** 切られるのは後ろからなので、注意や立ち寄り先のような
    /// 「ここでしか見られないもの」を、どこにでも出ている数字より先に置く。
    private static func items(for route: NavRoute) -> [CPInformationItem] {
        var items: [CPInformationItem] = []

        // MapKit が経路に付ける注意。有料道路の有無や「目的地まで道が繋がっていない」が
        // ここに来る（実測:「経路案内は目的地に最も近い道路で終了します。」）。
        for notice in route.advisoryNotices {
            items.append(CPInformationItem(title: String(localized: "注意"), detail: notice))
        }

        for waypoint in route.waypoints {
            items.append(CPInformationItem(title: String(localized: "立ち寄り先"), detail: waypoint.name))
        }

        items.append(CPInformationItem(title: String(localized: "距離"),
                                       detail: Formatters.distanceText(route.distance)))
        items.append(CPInformationItem(title: String(localized: "所要"),
                                       detail: Formatters.durationText(route.expectedTravelTime)))
        items.append(CPInformationItem(
            title: String(localized: "到着予定"),
            detail: Formatters.arrivalText(Date(timeIntervalSinceNow: route.expectedTravelTime))))

        items.append(CPInformationItem(title: String(localized: "目的地"), detail: route.destination.name))
        if !route.destination.subtitle.isEmpty {
            items.append(CPInformationItem(title: String(localized: "住所"),
                                           detail: route.destination.subtitle))
        }
        // 電話番号は**出すだけ**で、かける導線は付けない。CarPlay から `tel:` が通るかを
        // 確かめていないので、押しても何も起きないボタンを作らない。
        if let phone = route.destination.mapItem.phoneNumber, !phone.isEmpty {
            items.append(CPInformationItem(title: String(localized: "電話"), detail: phone))
        }

        return Array(items.prefix(maximumItems))
    }
}
