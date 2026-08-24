import Combine
import CoreLocation
import Foundation
import MapKit

/// 走った道を貯める。
///
/// カーナビは目的地のある日にしか開かれない。**これは目的地の無い日に開く理由**になる
/// 唯一の画面で、走った線が地図に積み上がっていくところと、通った都道府県・市区町村の
/// 数を出す。案内には一切関わらない。
///
/// **`NavigationController` ではなく `LocationService` を直に購読する。** 助言を出す層
/// （`RestReminder` ほか）が案内を購読しているのと分かれるのはここで、**いちばん塗りたいのは
/// 案内していない道**だから。通勤路や近所の買い物は目的地を入れずに走るので、案内している
/// 時間だけを数えると、毎日通る道がいつまでも白いままになる。
///
/// 裏返して、**残るのはアプリが動いているあいだだけ**。新しい許可も背景モードも足していない
/// （`LocationService.setNavigating` が背景測位を立てるのは案内中だけ）ので、案内せずに
/// 走ったぶんが残るのは、iPhone か CarPlay の画面を出している場合に限られる。
/// **要らない許可を増やしてまで完全な記録にはしない**、という判断。
@MainActor
final class TrackStore: ObservableObject {
    static let shared = TrackStore()

    /// 測位 1 回ぶん。ファイルに落とすのもこの形。
    struct Point: Equatable {
        let coordinate: CLLocationCoordinate2D
        let time: Date

        static func == (one: Point, other: Point) -> Bool {
            one.time == other.time
                && one.coordinate.latitude == other.coordinate.latitude
                && one.coordinate.longitude == other.coordinate.longitude
        }
    }

    /// ひと続きの走行。地図にはこれを 1 本の線として描く。
    struct Track: Identifiable {
        let id = UUID()
        let started: Date
        var coordinates: [CLLocationCoordinate2D]
        var distance: CLLocationDistance
    }

    /// 走ったことのある市区町村。
    struct Visit: Codable, Identifiable, Hashable {
        /// 都道府県（国外なら州・地方、それも取れなければ国名）。
        let prefecture: String
        /// 市区町村。政令指定都市は区に割らない（MapKit が「横浜市」までしか返さない）。
        let city: String
        let first: Date

        var id: String { "\(prefecture)/\(city)" }
    }

    /// 市区町村を引いた、という**その瞬間の出来事**。
    ///
    /// `visits` は貯まった結果なので、これとは別に要る。**`isFirst` は貯める前に
    /// 見た結果**で、`$visits` を購読しても後からは作れない（届いたときにはもう入っている）。
    /// 使うのは `VisitAdvisor` だけで、記録そのものには関わらない。
    struct Located: Equatable {
        let prefecture: String
        let city: String
        /// これまでに走ったことのない市区町村か。
        let isFirst: Bool
    }

    @Published private(set) var tracks: [Track] = []
    @Published private(set) var visits: [Visit] = []
    let located = PassthroughSubject<Located, Never>()

    /// 記録するかどうか。**切れるようにしてある**——どこを走ったかは、残すかどうかを
    /// 利用者が決めてよい種類のもの。既定は入り（切りで始めると、最初に開いた画面が
    /// 必ず空になり、何の機能なのか分からない）。
    @Published var isRecording: Bool {
        didSet { defaults.set(isRecording, forKey: Self.recordingKey) }
    }

    /// 記録する間隔。**停まっているあいだの揺れ（±10m ほど）で点が増えない**幅を取る。
    /// 地図に道として見せるだけなので、これ以上細かくしても絵は変わらない。
    static let minimumSpacing: CLLocationDistance = 50
    /// これより粗い測位は捨てる。`GuidanceEngine` が逸脱を数えないのと同じ考え方で、
    /// 誤差 100m の点を繋ぐと、走っていない道に線が引かれる。
    static let accuracyLimit: CLLocationAccuracy = 50
    /// 点と点がこれ以上離れていたら、別のひと続きにする。
    ///
    /// **繋いだままにしないこと。** アプリを閉じているあいだに移動したぶんは測っていないので、
    /// 繋ぐと**走っていない直線が街をまたいで引かれる**。
    static let splitDistance: CLLocationDistance = 500
    /// 同上。時間のほうが先に空くこともある（トンネル・信号待ちでの取りこぼし）。
    static let splitInterval: TimeInterval = 120
    /// 市区町村を引き直す間隔。逆ジオコーディングは連打しない（`DrivingSideLocator` と同じ）。
    /// 市区町村をまたいだことに気づける程度に短く、1 回の走行で数十回に収まる程度には長く。
    static let geocodeInterval: CLLocationDistance = 3_000

    private let defaults: UserDefaults
    private static let visitsKey = "tracks.visits"
    private static let recordingKey = "tracks.recording"

    private let file = TrackFile()
    /// 最後に記録した点。間引きと切れ目の判定に使う。
    private var last: Point?
    /// 最後に市区町村を引いた地点。
    private var geocodedNear: CLLocation?
    private var isGeocoding = false
    private var cancellables = Set<AnyCancellable>()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 未設定なら入り。`bool(forKey:)` は無いときも false を返すので、存在を見てから読む。
        isRecording = defaults.object(forKey: Self.recordingKey) as? Bool ?? true
        visits = (try? JSONDecoder().decode([Visit].self,
                                            from: defaults.data(forKey: Self.visitsKey) ?? Data())) ?? []
    }

    func start() {
        Task {
            let points = Self.decode(await file.load())
            tracks = Self.tracks(from: points)
            // **最後の点を引き継ぐ。** 引き継がないと、起動直後の 1 点が前回の続きから
            // 50m 以内でも記録され、しかも切れ目の判定を通らずに前の線へ繋がる。
            last = points.last
        }

        LocationService.shared.$location
            .compactMap { $0 }
            .sink { [weak self] in self?.handle(location: $0) }
            .store(in: &cancellables)
    }

    // MARK: - 集計

    var totalDistance: CLLocationDistance { tracks.reduce(0) { $0 + $1.distance } }

    /// 走った日の数。日をまたいだ走行は始めた日で数える。
    var days: Int {
        Set(tracks.map { Calendar.current.startOfDay(for: $0.started) }).count
    }

    /// 都道府県ごとにまとめた市区町村。並びは初めて走った順。
    var visitsByPrefecture: [(prefecture: String, cities: [Visit])] {
        let grouped = Dictionary(grouping: visits, by: \.prefecture)
        return grouped
            .map { (prefecture: $0.key, cities: $0.value.sorted { $0.first < $1.first }) }
            .sorted { ($0.cities.first?.first ?? .distantFuture) < ($1.cities.first?.first ?? .distantFuture) }
    }

    var prefectureCount: Int { Set(visits.map(\.prefecture)).count }

    // MARK: - 記録

    private func handle(location: CLLocation) {
        guard isRecording, Self.shouldRecord(location, after: last) else { return }

        let point = Point(coordinate: location.coordinate, time: location.timestamp)
        Self.extend(&tracks, with: point, after: last)
        last = point

        let record = Self.encode(point)
        Task { await file.append(record) }

        geocodeIfNeeded(at: location)
    }

    /// 記録に値する測位か。
    static func shouldRecord(_ location: CLLocation, after previous: Point?) -> Bool {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= accuracyLimit else { return false }
        guard let previous else { return true }
        return MKMapPoint(location.coordinate).distance(to: MKMapPoint(previous.coordinate)) >= minimumSpacing
    }

    /// 点を足す。**続きにするか別の線にするかの判定はここ 1 か所**で、
    /// ファイルから読み直すときも同じ関数を通る（`tracks(from:)`）。
    static func extend(_ tracks: inout [Track], with point: Point, after previous: Point?) {
        guard var track = tracks.last, let previous, !isBreak(from: previous, to: point) else {
            tracks.append(Track(started: point.time, coordinates: [point.coordinate], distance: 0))
            return
        }
        track.coordinates.append(point.coordinate)
        track.distance += MKMapPoint(previous.coordinate).distance(to: MKMapPoint(point.coordinate))
        tracks[tracks.count - 1] = track
    }

    static func tracks(from points: [Point]) -> [Track] {
        var result: [Track] = []
        var previous: Point?
        for point in points {
            extend(&result, with: point, after: previous)
            previous = point
        }
        return result
    }

    private static func isBreak(from previous: Point, to point: Point) -> Bool {
        let interval = point.time.timeIntervalSince(previous.time)
        if interval < 0 || interval > splitInterval { return true }
        return MKMapPoint(previous.coordinate).distance(to: MKMapPoint(point.coordinate)) > splitDistance
    }

    // MARK: - 市区町村

    private func geocodeIfNeeded(at location: CLLocation) {
        guard !isGeocoding else { return }
        // 圏外では必ず失敗する。投げるだけ無駄なので黙って見送る（`NavigationController` が
        // 引き直しを見送るのと同じ）。次に動いたときにまた来る。
        guard NetworkMonitor.shared.isOnline else { return }
        if let geocodedNear, location.distance(from: geocodedNear) < Self.geocodeInterval { return }

        isGeocoding = true
        Task {
            defer { isGeocoding = false }
            guard let visit = await Self.visit(at: location) else { return }
            // 引けたときだけ基準を進める。失敗を覚えると、次の測位でまた引いてしまう。
            geocodedNear = location
            remember(visit)
        }
    }

    /// 貯めて、流す。**`private` にしていないのはテストから呼ぶため**（`isFirst` は
    /// ここでしか決まらないので、外からは 2 度目かどうかを確かめようがない）。
    func remember(_ visit: Visit) {
        let isFirst = !visits.contains(where: { $0.id == visit.id })
        if isFirst {
            visits.append(visit)
            defaults.set(try? JSONEncoder().encode(visits), forKey: Self.visitsKey)
        }
        // **貯めてから流す。** 受け取った側が `visits` を読み直しても食い違わないように。
        // 初めてでなくても流すのは、都道府県をまたいだかどうかが**続けて引いた 2 件を
        // 比べないと分からない**ため（`VisitAdvisor`）。
        located.send(Located(prefecture: visit.prefecture, city: visit.city, isFirst: isFirst))
    }

    private static func visit(at location: CLLocation) async -> Visit? {
        guard let request = MKReverseGeocodingRequest(location: location),
              let address = try? await request.mapItems.first?.addressRepresentations,
              let city = address.cityName else { return nil }

        return Visit(prefecture: prefecture(in: address.cityWithContext, city: city) ?? address.regionName ?? "",
                     city: city,
                     first: Date())
    }

    /// 「岐阜県大野郡白川村」から「岐阜県」を取り出す。
    ///
    /// **`MKAddressRepresentations` に都道府県のプロパティは無い**（`cityName` /
    /// `cityWithContext` / `regionName` / `regionCode` だけ）ので、市区町村を引いた残りで見る。
    /// `CLPlacemark.administrativeArea` なら一発だが、**`CLGeocoder` は iOS 26.0 で
    /// deprecated** なので使わない。
    ///
    /// 英語の端末では "Cupertino, CA" のように区切りが入るので、残った記号は落とす。
    /// **市区町村しか返らない国（シンガポールなど）では空になる**ので、そのときは
    /// 何も返さない（呼び元が国名で埋める）。`context != city` を別に見る必要は無い——
    /// 引き算の結果が必ず空文字になるので、下の判定でそのまま拾える。
    static func prefecture(in context: String?, city: String) -> String? {
        guard let context else { return nil }

        let separators = CharacterSet(charactersIn: " ,、，・").union(.whitespacesAndNewlines)
        let remainder = context
            .replacingOccurrences(of: city, with: "")
            .trimmingCharacters(in: separators)
        return remainder.isEmpty ? nil : remainder
    }

    // MARK: - 消す

    func clear() {
        tracks = []
        visits = []
        last = nil
        geocodedNear = nil
        defaults.removeObject(forKey: Self.visitsKey)
        Task { await file.clear() }
    }

    // MARK: - ファイル

    /// 1 点ぶんの大きさ。緯度・経度・時刻の Float64 が 3 つ。
    static let recordSize = 24

    static func encode(_ point: Point) -> Data {
        var data = Data(capacity: recordSize)
        for value in [point.coordinate.latitude, point.coordinate.longitude, point.time.timeIntervalSince1970] {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decode(_ data: Data) -> [Point] {
        // `withUnsafeBytes` に渡すクロージャは MainActor の外なので、
        // 外側で読んでから持ち込む（静的プロパティを中で参照すると Swift 6 でエラー）。
        let size = recordSize
        let count = data.count / size
        guard count > 0 else { return [] }

        return data.withUnsafeBytes { raw in
            (0 ..< count).compactMap { index in
                func value(_ slot: Int) -> Double {
                    let bits = raw.loadUnaligned(fromByteOffset: index * size + slot * 8, as: UInt64.self)
                    return Double(bitPattern: UInt64(littleEndian: bits))
                }
                let coordinate = CLLocationCoordinate2D(latitude: value(0), longitude: value(1))
                // 途中で切れたファイル・壊れたファイルで地図が飛ばないように。
                guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
                return Point(coordinate: coordinate, time: Date(timeIntervalSince1970: value(2)))
            }
        }
    }
}

/// 走った道のファイル。**追記だけ**で、1 点ごとに 24 バイト書く。
///
/// まとめ書きにしていないのは、落ちたときに書けていないぶんが消えるから。24 バイトの
/// 追記は 50m に 1 回（時速 60km なら 3 秒に 1 回）しか来ないので、案内の邪魔にならない。
///
/// **刈り込みは入れていない。** 1 時間走っておよそ 30KB なので、300 時間で 10MB ほど。
/// 増え方が問題になるようなら、古い順に落とすか線を間引く。
private actor TrackFile {
    private let url: URL

    init() {
        let directory = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appending(path: "tracks.bin")
    }

    func append(_ data: Data) {
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? data.write(to: url)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    func load() -> Data {
        (try? Data(contentsOf: url)) ?? Data()
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
