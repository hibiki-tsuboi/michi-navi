import Combine
import CoreLocation
import Foundation
import MapKit

/// 履歴とお気に入りの保存。iPhone 画面と CarPlay 画面が同じものを見る。
///
/// 多くの車では走行中にキーボードが無効になるため、ここに貯まった地点が
/// CarPlay で目的地を選ぶ現実的な手段になる。CarPlay ガイドラインの
/// 「すべての操作が iPhone を触らずに完結すること」はこれで満たす。
@MainActor
final class DestinationStore: ObservableObject {
    static let shared = DestinationStore()

    /// 履歴の保持件数。運転中に読める量を超えて貯めても選べないので絞る。
    private let recentsLimit = 20

    @Published private(set) var recents: [Place] = []
    @Published private(set) var favorites: [Place] = []
    /// 最後に着いた地点。**そこに車を置いた**とみなす。
    @Published private(set) var parking: ParkedCar?

    /// ピン留めした行き先。お気に入りとは別に持つ。
    @Published private(set) var home: Place?
    @Published private(set) var work: Place?

    private let defaults: UserDefaults
    private let recentsKey = "destinations.recents"
    private let favoritesKey = "destinations.favorites"
    private let parkingKey = "destinations.parking"
    private let visitsKey = "destinations.visits"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recents = load(key: recentsKey)
        favorites = load(key: favoritesKey)
        parking = loadParking()
        visits = (defaults.data(forKey: visitsKey)
            .flatMap { try? JSONDecoder().decode([String: [Date]].self, from: $0) }) ?? [:]
        home = loadPlace(key: Pinned.home.key)
        work = loadPlace(key: Pinned.work.key)
    }

    // MARK: - 自宅・職場

    /// 常に 1 タップで届かせる行き先。
    ///
    /// **お気に入りで代用しない。** あちらは件数が増えるほど 1 件あたりが遠くなるのに対し、
    /// この 2 つは実際のカーナビでいちばん押される行き先で、しかも数が増えない。
    /// 走行中はキーボードが塞がれる（`CPSessionConfiguration.limitedUserInterfaces`）ので、
    /// 「検索を使わずに目的地へ届く経路を残す」という要件の中でもいちばん短い経路になる。
    enum Pinned: String, CaseIterable {
        case home
        case work

        var title: String {
            switch self {
            case .home: String(localized: "自宅")
            case .work: String(localized: "職場")
            }
        }

        var symbol: String {
            switch self {
            case .home: "house.fill"
            case .work: "briefcase.fill"
            }
        }

        var key: String { "destinations.pinned.\(rawValue)" }
    }

    func place(_ kind: Pinned) -> Place? {
        switch kind {
        case .home: home
        case .work: work
        }
    }

    /// 設定・解除。`nil` を渡すと解除。
    ///
    /// **設定できるのは iPhone 側だけ**（`ContentView`）。どこを自宅にするかを決めるには
    /// 検索が要り、走行中はその検索が使えない。CarPlay 側に「押しても何も起きない導線」を
    /// 作らないため、あちらは設定済みのものを出すだけにしてある。
    func set(_ place: Place?, as kind: Pinned) {
        switch kind {
        case .home: home = place
        case .work: work = place
        }
        savePlace(place, key: kind.key)
    }

    /// 車をとめた場所。
    ///
    /// 到着＝降りる、と決め打ちしている。降りずに走り出せば次の案内で上書きされるので、
    /// 間違っていても害が残らない。逆に「本当に降りたか」を判定しようとすると、
    /// 停車の検知と駐車の区別が要って外しやすい。
    struct ParkedCar: Codable, Equatable {
        let place: Place
        let date: Date
    }

    /// 案内を始めた目的地を履歴の先頭に入れる。同じ場所は 1 件にまとめる。
    func remember(_ place: Place) {
        recents.removeAll { $0 == place }
        recents.insert(place, at: 0)
        if recents.count > recentsLimit {
            recents.removeLast(recents.count - recentsLimit)
        }
        save(recents, key: recentsKey)
        rememberVisit(of: place)
    }

    // MARK: - いつ行く場所か

    /// 案内を始めた時刻の記録。キーは `Place.id`、値は新しい順の時刻。
    ///
    /// **場所そのものは持たない。** 履歴（`recents`）に載っているものだけを対象にして、
    /// 落ちた場所の記録は捨てる。ここが独立して増えると、消したはずの行き先が
    /// 並べ替えにだけ効き続けることになる。
    private var visits: [String: [Date]] = [:]

    /// 1 か所につき覚える件数。**増やさないこと。** 効くのは直近の習慣で、
    /// 半年前の 1 回で並びが変わるほうが害になる。
    private let visitLimit = 10
    /// この時間差までを「同じ時間帯」とみなす（分）。
    ///
    /// **時の成分だけで比べないこと。** 23:30 と 21:00 が「23 と 21 で 2 時間差」に
    /// なってしまい、窓が実質 3 時間近くまで広がる。分まで見れば端がぶれない。
    private static let windowMinutes = 120
    /// 引き上げるのに要る回数。**1 回では引き上げない。** たまたま寄っただけの場所が
    /// 毎日その時刻に先頭へ出てくると、履歴が信用できなくなる。
    private static let minimumVisits = 2

    private func rememberVisit(of place: Place) {
        var history = visits[place.id] ?? []
        history.insert(Date(), at: 0)
        if history.count > visitLimit { history.removeLast(history.count - visitLimit) }
        visits[place.id] = history

        let living = Set(recents.map(\.id))
        visits = visits.filter { living.contains($0.key) }
        defaults.set(try? JSONEncoder().encode(visits), forKey: visitsKey)
    }

    /// いまの時間帯によく行く場所。**履歴の中から拾う。**
    ///
    /// 走行中はキーボードが塞がれるので、行き先に届く速さは「一覧の上のほうにあるか」で
    /// ほぼ決まる。朝は職場・夕方は自宅という一番太い線は `Pinned` が受け持つが、
    /// 週に何度か決まった時間に行く場所（送り迎え・買い物）はピンの 2 枠に入らない。
    ///
    /// **お気に入りは並べ替えない。** あちらは利用者が自分で並べたもので、位置が動くと
    /// 「どこにあるか」を覚え直すことになる。履歴はもともと最近順で動き続けるので、
    /// 順序が変わっても無理がない。
    ///
    /// 曜日は平日と休日だけで見る。曜日ごとに分けると 1 曜日あたりの回数が減って、
    /// `minimumVisits` に届くまでに何週間もかかる。
    func frequentDestinations(at date: Date = Date(), limit: Int = 3) -> [Place] {
        let calendar = Calendar.current
        let isWeekend = calendar.isDateInWeekend(date)

        let matched = recents.filter { place in
            let hits = (visits[place.id] ?? []).filter { visit in
                calendar.isDateInWeekend(visit) == isWeekend
                    && Self.minuteDistance(visit, date, calendar: calendar) <= Self.windowMinutes
            }
            return hits.count >= Self.minimumVisits
        }
        return Array(matched.prefix(limit))
    }

    /// 1 日の中での時刻の差（分）。**時計は 24 時間で一周する**ので、23:30 と 0:30 は
    /// 1 時間差として数える。日付は見ない（「毎日この時刻」を拾いたいので）。
    private static func minuteDistance(_ lhs: Date, _ rhs: Date, calendar: Calendar) -> Int {
        func minutes(_ date: Date) -> Int {
            calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        }
        let difference = abs(minutes(lhs) - minutes(rhs))
        return min(difference, 24 * 60 - difference)
    }

    func isFavorite(_ place: Place) -> Bool {
        favorites.contains(place)
    }

    func toggleFavorite(_ place: Place) {
        if let index = favorites.firstIndex(of: place) {
            favorites.remove(at: index)
        } else {
            favorites.append(place)
        }
        save(favorites, key: favoritesKey)
    }

    func clearRecents() {
        recents = []
        save(recents, key: recentsKey)
        // 履歴を消したら「いつ行く場所か」も消える。残すと、一覧に無い場所の記録だけが
        // 生き続けることになる。
        visits = [:]
        defaults.removeObject(forKey: visitsKey)
    }

    // MARK: - 駐車位置

    /// 着いた地点を車の置き場所として覚える。
    ///
    /// **目的地の座標ではなく実際に着いた座標**を使う。目的地が施設なら、車は
    /// たいてい入口ではなく駐車場にある。名前は目的地から借りて「どこの」が分かるようにする。
    func rememberParking(at coordinate: CLLocationCoordinate2D, near destination: Place) {
        let item = MKMapItem(location: CLLocation(latitude: coordinate.latitude,
                                                  longitude: coordinate.longitude),
                             address: nil)
        let place = Place(mapItem: item, fallbackName: String(localized: "\(destination.name) の駐車位置"))
        parking = ParkedCar(place: place, date: Date())
        saveParking()
    }

    func clearParking() {
        parking = nil
        saveParking()
    }

    private func loadParking() -> ParkedCar? {
        guard let data = defaults.data(forKey: parkingKey) else { return nil }
        return try? JSONDecoder().decode(ParkedCar.self, from: data)
    }

    private func saveParking() {
        guard let parking else {
            defaults.removeObject(forKey: parkingKey)
            return
        }
        defaults.set(try? JSONEncoder().encode(parking), forKey: parkingKey)
    }

    // MARK: - 保存

    private func load(key: String) -> [Place] {
        guard let data = defaults.data(forKey: key) else { return [] }
        do {
            return try JSONDecoder().decode([Place].self, from: data)
        } catch {
            // 形式が変わって読めなくなっても、案内は続けられる方が大事なので握りつぶす。
            NSLog("[MichiNavi] \(key) の読み込みに失敗: \(error.localizedDescription)")
            return []
        }
    }

    private func loadPlace(key: String) -> Place? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Place.self, from: data)
    }

    private func savePlace(_ place: Place?, key: String) {
        guard let place else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(try? JSONEncoder().encode(place), forKey: key)
    }

    private func save(_ places: [Place], key: String) {
        do {
            defaults.set(try JSONEncoder().encode(places), forKey: key)
        } catch {
            NSLog("[MichiNavi] \(key) の保存に失敗: \(error.localizedDescription)")
        }
    }
}
