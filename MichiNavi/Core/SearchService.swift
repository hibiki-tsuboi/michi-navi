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

        let response: MKLocalSearch.Response
        do {
            response = try await MKLocalSearch(request: request).start()
        } catch {
            guard Self.isPlacemarkNotFound(error) else { throw error }
            return []
        }
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

        // **点ごとに失敗を受け取る。** 1 つでも投げると全体が落ちる作りにしないため
        // （[merge] の説明）。
        var found: [(index: Int, places: [Place])] = []
        var failures: [Error] = []
        await withTaskGroup(of: (Int, Result<[Place], Error>).self) { group in
            for (index, coordinate) in samples.enumerated() {
                group.addTask { [self] in
                    do {
                        return (index, .success(try await nearby(pointsOfInterest: pointsOfInterest,
                                                                 around: coordinate,
                                                                 radius: radius)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            for await (index, result) in group {
                switch result {
                case let .success(places): found.append((index, places))
                case let .failure(error): failures.append(error)
                }
            }
        }
        return try Self.merge(found, failures: failures)
    }

    /// 検索点ごとの結果を 1 本に束ねる。
    ///
    /// **手前の検索点で見つかったものを先に出す。** 同じ店が隣り合う検索点の両方に入るので、
    /// 先に見つかった側を残して重複を落とす。
    ///
    /// **失敗した点は飲む。ただし 1 件も拾えていないときだけ投げ直す。** 点のどれか 1 つが
    /// 落ちただけで全体を捨てると、4 点で見つかっていても結果がゼロになる
    /// （2026-08-22 まではそうなっていた。`withThrowingTaskGroup` の `for try await` が
    /// 最初の失敗でグループごと畳んでいた）。逆に全部飲むと、圏外で 5 点とも落ちたときに
    /// 「この先には見つかりませんでした」と言うことになる——**通信できていないことと、
    /// 探したが無かったことは別**なので、そこは区別して伝える。
    static func merge(_ results: [(index: Int, places: [Place])],
                      failures: [Error]) throws -> [Place] {
        var seen = Set<Place>()
        let places = results
            .sorted { $0.index < $1.index }
            .flatMap(\.places)
            .filter { seen.insert($0).inserted }

        if places.isEmpty, let failure = failures.first { throw failure }
        return places
    }

    /// 「探したが無かった」を表すエラーか。
    ///
    /// **MapKit は 0 件を空配列ではなく失敗として返す**（`MKErrorDomain` code 4
    /// ＝`MKError.placemarkNotFound`。2026-08-22 に太平洋の真ん中で `.winery` を
    /// 探して実測）。見つからないのは検索としては正常な結果なので、ここだけ
    /// 空配列に読み替える。
    ///
    /// **ほかのエラーは通すこと。** 圏外・レート制限まで空配列にすると、通信できて
    /// いないのに「近くに見つかりませんでした」と言うことになり、利用者は電波を
    /// 疑えなくなる。
    static func isPlacemarkNotFound(_ error: Error) -> Bool {
        (error as? MKError)?.code == .placemarkNotFound
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

    /// **0 件は空配列で返す**（[isPlacemarkNotFound]）。呼び元はどこも「見つからなかった」
    /// ときの文言を持っているのに、MapKit の失敗が先に届くせいで一度も出ていなかった
    /// （`CarPlayVoiceControl.Failure.notFound` と `SearchSheet` の
    /// 「場所が特定できませんでした」）。
    private func places(for request: MKLocalSearch.Request) async throws -> [Place] {
        do {
            let response = try await MKLocalSearch(request: request).start()
            return response.mapItems.map { Place(mapItem: $0) }
        } catch {
            guard Self.isPlacemarkNotFound(error) else { throw error }
            return []
        }
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
