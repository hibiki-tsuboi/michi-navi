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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recents = load(key: recentsKey)
        favorites = load(key: favoritesKey)
        parking = loadParking()
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
