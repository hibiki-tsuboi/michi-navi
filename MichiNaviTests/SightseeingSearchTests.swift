import MapKit
import Testing
@testable import MichiNavi

@MainActor
struct SightseeingSearchTests {
    private let origin = CLLocationCoordinate2D(latitude: 36.2548073, longitude: 136.9057953)

    private func item(_ name: String, coordinate: CLLocationCoordinate2D? = nil,
                      category: MKPointOfInterestCategory? = nil) -> MKMapItem {
        let coordinate = coordinate ?? origin
        let item = MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
        item.name = name
        item.pointOfInterestCategory = category
        return item
    }

    @Test("カテゴリが無い神社は拾い、同名の店や駐車場は除く")
    func recognizesShrinesWithoutCategories() {
        let items = [item("白川八幡神社"), item("白川八幡神社駐車場", category: .parking),
                     item("神社前カフェ", category: .cafe), item("神宮", category: .restaurant),
                     item("八幡神社駐車場"), item("八幡神社前"), item("Example Shrine"),
                     item("史跡", category: .landmark), item("白川村荻町地区", category: .landmark)]
        let spots = SightseeingSearch.spots(from: items, around: origin)
        #expect(spots.map(\.name) == ["白川八幡神社", "Example Shrine", "史跡"])
    }

    @Test("検索範囲の外や空の名前を紹介しない")
    func rejectsDistantAndUnnamedResults() {
        let far = CLLocationCoordinate2D(latitude: 35, longitude: 139)
        let items = [item("   ", category: .landmark), item("遠方神社", coordinate: far), item("白川八幡神社")]
        #expect(SightseeingSearch.spots(from: items, around: origin).map(\.name) == ["白川八幡神社"])
    }

    @Test("検索方法や座標の揺れで同じ施設が複数にならない")
    func mergesDuplicateResults() {
        let shifted = CLLocationCoordinate2D(latitude: origin.latitude + 0.0001, longitude: origin.longitude)
        let items = [item("白川八幡神社"), item("白川八幡神社", coordinate: shifted)]
        #expect(SightseeingSearch.spots(from: items, around: origin).count == 1)
    }

    @Test("同名の寺でも場所が違えば別の由緒を付けない")
    func factsRequireNameAndLocation() {
        #expect(SightseeingFacts.detail(for: "白川八幡神社", at: origin) != nil)
        #expect(SightseeingFacts.detail(for: "善光寺", at: origin) == nil)
        #expect(SightseeingFacts.detail(for: "白川八幡神社駐車場", at: origin) == nil)
        #expect(SightseeingFacts.detail(for: "未知神社", at: origin) == nil)
        #expect(SightseeingSearch.spots(from: [item("未知神社")], around: origin).first?.detail == nil)
    }
}
