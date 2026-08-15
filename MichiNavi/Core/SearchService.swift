import MapKit

/// 目的地検索。CarPlay の `CPSearchTemplate` は 1 文字ごとに候補を求めてくるので、
/// 入力中は `MKLocalSearchCompleter`（軽い・レート制限が緩い）、
/// 確定時だけ `MKLocalSearch`（座標が取れる）を使い分ける。
@MainActor
final class SearchService: NSObject {
    static let shared = SearchService()

    private let completer = MKLocalSearchCompleter()
    private var pendingHandler: (([MKLocalSearchCompletion]) -> Void)?

    override init() {
        super.init()
        completer.resultTypes = [.address, .pointOfInterest]
        completer.delegate = self
    }

    // MARK: - 入力中の候補

    /// 入力途中の文字列に対する補完候補を返す。
    /// 続けて呼ばれた場合、前回のハンドラは空配列で決着させて取りこぼしを防ぐ。
    func suggest(_ text: String,
                 near region: MKCoordinateRegion?,
                 handler: @escaping ([MKLocalSearchCompletion]) -> Void) {
        pendingHandler?([])
        pendingHandler = nil

        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            handler([])
            return
        }

        pendingHandler = handler
        if let region { completer.region = region }
        completer.queryFragment = query
    }

    func cancelSuggestions() {
        completer.cancel()
        pendingHandler?([])
        pendingHandler = nil
    }

    // MARK: - 確定検索

    /// 補完候補を実際の座標付き地点に解決する。
    func resolve(_ completion: MKLocalSearchCompletion) async throws -> [Place] {
        try await places(for: MKLocalSearch.Request(completion: completion))
    }

    /// フリーワードでそのまま検索する（iPhone 側の検索ボタンなど）。
    func search(_ query: String, near region: MKCoordinateRegion?) async throws -> [Place] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.address, .pointOfInterest]
        if let region { request.region = region }
        return try await places(for: request)
    }

    /// 現在地のまわりをカテゴリで探す（ガソリンスタンド、駐車場など）。
    /// キーボードが使えない走行中でも目的地を選べるようにするための入口。
    func nearby(pointsOfInterest: [MKPointOfInterestCategory],
                around coordinate: CLLocationCoordinate2D,
                radius: CLLocationDistance = 10_000) async throws -> [Place] {
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: radius)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: pointsOfInterest)

        let response = try await MKLocalSearch(request: request).start()
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        // 運転中は近い順が唯一まともな並び。MapKit は距離順を保証しない。
        return response.mapItems
            .map { Place(mapItem: $0) }
            .sorted { lhs, rhs in
                origin.distance(from: CLLocation(latitude: lhs.coordinate.latitude,
                                                 longitude: lhs.coordinate.longitude))
                    < origin.distance(from: CLLocation(latitude: rhs.coordinate.latitude,
                                                       longitude: rhs.coordinate.longitude))
            }
    }

    /// 経路の先に沿ってカテゴリで探す。
    ///
    /// 走行中は「近い」より「これから通る」ほうが役に立つ。現在地のまわりを探すと、
    /// もう通り過ぎた店や、経路から大きく外れる店が上位に来てしまう。
    ///
    /// MapKit に経路沿い検索は無いので、経路上へ一定間隔で検索点を置き、
    /// それぞれのまわりを探して束ねる。検索点の数は抑える。増やすほど
    /// MapKit のレート制限に近づくうえ、運転中に選べる件数を超える。
    func alongRoute(pointsOfInterest: [MKPointOfInterestCategory],
                    coordinates: [CLLocationCoordinate2D],
                    radius: CLLocationDistance = 5_000) async throws -> [Place] {
        // 円がだいたい隙間なく並ぶよう、間隔は半径の 2 倍にする。
        let samples = Self.samplePoints(along: coordinates, every: radius * 2)
        guard !samples.isEmpty else { return [] }

        var found: [(index: Int, places: [Place])] = []
        try await withThrowingTaskGroup(of: (Int, [Place]).self) { group in
            for (index, coordinate) in samples.enumerated() {
                group.addTask { [self] in
                    (index, try await nearby(pointsOfInterest: pointsOfInterest,
                                             around: coordinate,
                                             radius: radius))
                }
            }
            for try await result in group { found.append(result) }
        }

        // 手前の検索点で見つかったものを先に出す。同じ店が隣り合う検索点の
        // 両方に入るので、先に見つかった側を残して重複を落とす。
        var seen = Set<Place>()
        return found
            .sorted { $0.index < $1.index }
            .flatMap(\.places)
            .filter { seen.insert($0).inserted }
    }

    /// 経路沿いに置く検索点の上限。
    private static let maximumSamples = 5

    /// 経路上に `interval` ごとの検索点を置く。先頭（＝いまいる場所）は必ず含める。
    private static func samplePoints(along coordinates: [CLLocationCoordinate2D],
                                     every interval: CLLocationDistance) -> [CLLocationCoordinate2D] {
        guard let first = coordinates.first else { return [] }

        var samples = [first]
        var travelled: CLLocationDistance = 0
        var previous = MKMapPoint(first)

        for coordinate in coordinates.dropFirst() {
            let point = MKMapPoint(coordinate)
            travelled += point.distance(to: previous)
            previous = point

            guard travelled >= interval else { continue }
            samples.append(coordinate)
            travelled = 0
            if samples.count >= maximumSamples { break }
        }
        return samples
    }

    private func places(for request: MKLocalSearch.Request) async throws -> [Place] {
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.map { Place(mapItem: $0) }
    }
}

extension SearchService: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            let handler = pendingHandler
            pendingHandler = nil
            handler?(completer.results)
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            let handler = pendingHandler
            pendingHandler = nil
            handler?([])
        }
    }
}
