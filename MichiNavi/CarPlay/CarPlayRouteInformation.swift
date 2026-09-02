import CarPlay
import Foundation

/// ルート提示中にドライブブリーフを見せる画面（`CPInformationTemplate`）。
///
/// **候補一覧の 1 行に収まらない情報を出すためにある。** 一覧にはブリーフの短縮形を入れるが、
/// 狭い画面では距離・時間だけの variant へ落ちる。ここなら注意、日差しが続く時間、右左折の
/// 回数、立ち寄り先を項目として読める。MapKit の `advisoryNotices` は経路ごとに異なる
/// （実測: 渋谷→成城で候補 1・3 が「通行料の支払いが必要です」、候補 2 は無し）。
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
        return CPInformationTemplate(title: String(localized: "ドライブブリーフ"),
                                     layout: .leading,
                                     items: items(for: route),
                                     actions: [start])
    }

    /// **決め手になる順に並べる。** 切られるのは後ろからなので、注意や立ち寄り先のような
    /// 「ここでしか見られないもの」を、どこにでも出ている数字より先に置く。
    private static func items(for route: NavRoute) -> [CPInformationItem] {
        var items: [CPInformationItem] = []

        let brief = route.driveBrief ?? DriveBrief.make(for: route,
                                                        comparisonTags: [],
                                                        departure: Date())
        for item in brief.items {
            items.append(CPInformationItem(title: item.title, detail: item.detail))
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
