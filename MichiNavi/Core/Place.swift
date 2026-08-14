import CoreLocation
import MapKit

/// 目的地として扱える 1 地点。検索結果・履歴・お気に入りで共通に使う。
struct Place: Identifiable, Equatable {
    let id: UUID
    let name: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D
    let mapItem: MKMapItem

    init(mapItem: MKMapItem, fallbackName: String? = nil) {
        id = UUID()
        self.mapItem = mapItem
        name = mapItem.name ?? fallbackName ?? "目的地"
        subtitle = Place.addressLine(for: mapItem)
        coordinate = mapItem.location.coordinate
    }

    static func == (lhs: Place, rhs: Place) -> Bool { lhs.id == rhs.id }

    /// 「東京都渋谷区道玄坂1-2-3」のような 1 行住所。
    /// CarPlay のリストは 1 行しか出ないので、短い表記があればそちらを優先する。
    private static func addressLine(for mapItem: MKMapItem) -> String {
        if let address = mapItem.address {
            return address.shortAddress ?? address.fullAddress
        }
        return mapItem.addressRepresentations?.fullAddress(includingRegion: true, singleLine: true) ?? ""
    }
}
