import CoreLocation
import MapKit

/// 目的地として扱える 1 地点。検索結果・履歴・お気に入りで共通に使う。
struct Place: Identifiable {
    /// 同じ場所なら毎回同じ値になる ID。履歴の重複排除と保存に使う。
    let id: String
    let name: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D
    let mapItem: MKMapItem

    init(mapItem: MKMapItem, fallbackName: String? = nil) {
        self.mapItem = mapItem
        name = mapItem.name ?? fallbackName ?? String(localized: "目的地")
        subtitle = Place.addressLine(for: mapItem)
        coordinate = mapItem.location.coordinate
        id = Place.identifier(for: mapItem, name: name, coordinate: coordinate)
    }

    /// 「東京都渋谷区道玄坂1-2-3」のような 1 行住所。
    /// CarPlay のリストは 1 行しか出ないので、短い表記があればそちらを優先する。
    private static func addressLine(for mapItem: MKMapItem) -> String {
        if let address = mapItem.address {
            return address.shortAddress ?? address.fullAddress
        }
        return mapItem.addressRepresentations?.fullAddress(includingRegion: true, singleLine: true) ?? ""
    }

    /// MapKit が地点固有の識別子を持っていればそれを使う。
    /// 住所や座標だけの結果は識別子を持たないので、名前と座標から組み立てる。
    /// 座標は小数 5 桁（約 1m）に丸めて、測位のわずかな揺れで別物にならないようにする。
    private static func identifier(for mapItem: MKMapItem,
                                   name: String,
                                   coordinate: CLLocationCoordinate2D) -> String {
        if let identifier = mapItem.identifier?.rawValue { return identifier }
        return String(format: "%@@%.5f,%.5f", name, coordinate.latitude, coordinate.longitude)
    }
}

extension Place: Equatable {
    static func == (lhs: Place, rhs: Place) -> Bool { lhs.id == rhs.id }
}

extension Place: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - 保存

extension Place: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, subtitle, latitude, longitude
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        subtitle = try container.decode(String.self, forKey: .subtitle)

        let latitude = try container.decode(CLLocationDegrees.self, forKey: .latitude)
        let longitude = try container.decode(CLLocationDegrees.self, forKey: .longitude)
        coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)

        // MKMapItem はそのまま保存できないため座標から組み直す。
        // ルート計算に渡すのは座標なので、これで足りる。
        mapItem = MKMapItem(location: CLLocation(latitude: latitude, longitude: longitude),
                            address: nil)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(subtitle, forKey: .subtitle)
        try container.encode(coordinate.latitude, forKey: .latitude)
        try container.encode(coordinate.longitude, forKey: .longitude)
    }
}
