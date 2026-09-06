import CoreLocation
import Foundation

/// 施設・観光協会の公式情報を短く要約した原稿。出典確認: 2026-09-06。
/// 同名の寺社へ別の由緒を付けないよう、名前と場所の両方が合う場合だけ使う。
enum SightseeingFacts {
    struct Entry: Identifiable {
        let id: String
        let name: String
        let aliases: [String]
        let coordinate: CLLocationCoordinate2D
        let detail: String
        let source: String
    }

    static let entries: [Entry] = [
        Entry(id: "shirakawa-hachiman", name: String(localized: "白川八幡神社"),
              aliases: ["白川八幡神社", "白川八幡宮", "Shirakawa Hachiman Shrine", "Shirakawa Hachiman Jinja"],
              coordinate: CLLocationCoordinate2D(latitude: 36.2548073, longitude: 136.9057953),
              detail: String(localized: "どぶろく祭りで知られる神社です。"),
              source: "https://www.vill.shirakawa.lg.jp/1349.htm"),
        Entry(id: "tsurugaoka-hachimangu", name: String(localized: "鶴岡八幡宮"),
              aliases: ["鶴岡八幡宮", "Tsurugaoka Hachimangu", "Tsurugaoka Hachimangu Shrine"],
              coordinate: CLLocationCoordinate2D(latitude: 35.3261049, longitude: 139.5563516),
              detail: String(localized: "源頼朝が鎌倉のこの場所に移した神社です。"),
              source: "https://www.hachimangu.or.jp/knowledge/"),
        Entry(id: "zenkoji-nagano", name: String(localized: "善光寺"),
              aliases: ["善光寺", "Zenkoji", "Zenkoji Temple", "Zenko-ji Temple"],
              coordinate: CLLocationCoordinate2D(latitude: 36.6616202, longitude: 138.1876928),
              detail: String(localized: "特定の宗派に属さないお寺です。"),
              source: "https://www.zenkoji.jp/about/"),
        Entry(id: "atsuta-jingu", name: String(localized: "熱田神宮"),
              aliases: ["熱田神宮", "Atsuta Jingu", "Atsuta Shrine", "Atsuta Jingu Shrine"],
              coordinate: CLLocationCoordinate2D(latitude: 35.1273434, longitude: 136.9086948),
              detail: String(localized: "三種の神器の一つ、草薙の剣をご神体とする神社です。"),
              source: "https://www.atsutajingu.or.jp/jingu/about/enshrined.html"),
        Entry(id: "matsumoto-castle", name: String(localized: "松本城"),
              aliases: ["松本城", "国宝 松本城", "国宝松本城", "Matsumoto Castle"],
              coordinate: CLLocationCoordinate2D(latitude: 36.238614, longitude: 137.9688621),
              detail: String(localized: "五重六階の天守が残る国宝のお城です。"),
              source: "https://www.matsumoto-castle.jp/about/tower"),
        Entry(id: "inuyama-castle", name: String(localized: "犬山城"),
              aliases: ["犬山城", "国宝 犬山城", "国宝犬山城", "Inuyama Castle"],
              coordinate: CLLocationCoordinate2D(latitude: 35.388289, longitude: 136.9392532),
              detail: String(localized: "木曽川のほとりに立つ、国宝の天守を持つお城です。"),
              source: "https://inuyama.gr.jp/experience/detail/1/")
    ]

    static func detail(for name: String, at coordinate: CLLocationCoordinate2D) -> String? {
        let normalized = SightseeingSearch.normalized(name)
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return entries.first { entry in
            entry.aliases.contains { SightseeingSearch.normalized($0) == normalized }
                && location.distance(from: CLLocation(latitude: entry.coordinate.latitude,
                                                       longitude: entry.coordinate.longitude)) < 300
        }?.detail
    }
}
