import Combine
import Foundation

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

    private let defaults: UserDefaults
    private let recentsKey = "destinations.recents"
    private let favoritesKey = "destinations.favorites"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recents = load(key: recentsKey)
        favorites = load(key: favoritesKey)
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

    private func save(_ places: [Place], key: String) {
        do {
            defaults.set(try JSONEncoder().encode(places), forKey: key)
        } catch {
            NSLog("[MichiNavi] \(key) の保存に失敗: \(error.localizedDescription)")
        }
    }
}
