import MapKit

/// 名称と場所は MapKit、解説は出典付きの原稿から取る。検索結果から由緒を推測しない。
enum SightseeingSearch {
    static let radius: CLLocationDistance = 1_500
    private static let categories: [MKPointOfInterestCategory] = [
        .landmark, .castle, .fortress, .nationalMonument, .museum
    ]

    static func nearby(_ coordinate: CLLocationCoordinate2D) async throws -> [SightseeingSpot] {
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: radius)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: categories)
        var items: [MKMapItem] = []
        var succeeded = false
        var lastError: Error?
        do {
            items = try await search(MKLocalSearch(request: request))
            succeeded = true
        } catch { lastError = error }

        // MapKit に神社・寺のカテゴリは無い。名称検索も行い、駐車場や同名の店は下で除く。
        for query in [String(localized: "神社"), String(localized: "寺院")] {
            try Task.checkCancellation()
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.resultTypes = .pointOfInterest
            request.region = MKCoordinateRegion(center: coordinate,
                                                latitudinalMeters: radius * 2,
                                                longitudinalMeters: radius * 2)
            do {
                items += try await search(MKLocalSearch(request: request))
                succeeded = true
            } catch { lastError = error }
        }
        try Task.checkCancellation()
        if !succeeded, let lastError { throw lastError }
        return spots(from: items, around: coordinate)
    }

    static func spots(from items: [MKMapItem], around coordinate: CLLocationCoordinate2D) -> [SightseeingSpot] {
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var result: [SightseeingSpot] = []
        for item in items {
            guard let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty, name.count <= 50,
                  CLLocationCoordinate2DIsValid(item.location.coordinate),
                  origin.distance(from: item.location) <= radius,
                  isLandmark(name: name, category: item.pointOfInterestCategory) else { continue }
            let place = Place(mapItem: item)
            let spot = SightseeingSpot(id: place.id, name: name, coordinate: place.coordinate,
                                       detail: SightseeingFacts.detail(for: name, at: place.coordinate))
            // 同じ施設がカテゴリ検索と名称検索の両方に出る。別 ID でも近ければ一つにする。
            guard !result.contains(where: { $0.isSamePlace(as: spot) }) else { continue }
            result.append(spot)
        }
        return result
    }

    static func isLandmark(name: String, category: MKPointOfInterestCategory?) -> Bool {
        // 地区全体の代表点は車の左右を表さない。実検索では荻町地区も landmark で返る。
        if ["地区", "地域", "エリア", " district", " area"].contains(where: { normalized(name).hasSuffix($0) }) {
            return false
        }
        if let category { return categories.contains(category) }
        let name = normalized(name)
        return ["神社", "神宮", "大社", "八幡宮", "天満宮", "東照宮", "寺", "寺院", "大仏"]
            .contains { name.hasSuffix($0) }
            || [" shrine", " temple"].contains { name.hasSuffix($0) }
    }

    static func normalized(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func search(_ search: MKLocalSearch) async throws -> [MKMapItem] {
        let operation = Operation(search)
        do {
            let response = try await withTaskCancellationHandler {
                try await operation.search.start()
            } onCancel: {
                Task { @MainActor in operation.search.cancel() }
            }
            try Task.checkCancellation()
            return response.mapItems
        } catch {
            try Task.checkCancellation()
            if (error as? MKError)?.code == .placemarkNotFound { return [] }
            throw error
        }
    }

    /// MapKit のオブジェクトを別スレッドへ渡さず、取り消しも作成元の actor で行う。
    @MainActor
    private final class Operation {
        let search: MKLocalSearch
        init(_ search: MKLocalSearch) { self.search = search }
    }
}
