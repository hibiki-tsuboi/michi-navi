import Combine
import CoreLocation
import OSLog

/// CarPlay 接続中の観光音声。GPS は既存のものを使い、検索待ちの場所を後から読み上げない。
@MainActor
final class SightseeingAdvisor: ObservableObject {
    static let shared = SightseeingAdvisor()
    let notice = PassthroughSubject<SightseeingGuide.Notice, Never>()

    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: "sightseeing.enabled")
            if !isEnabled { cancelSearch() }
        }
    }

    private let defaults: UserDefaults
    private let search: (CLLocationCoordinate2D) async throws -> [SightseeingSpot]
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MichiNavi", category: "sightseeing")
    @Published private(set) var isConnected = false
    private var connections = Set<String>()
    private var guide = SightseeingGuide()
    private var spots: [SightseeingSpot] = []
    private var searchOrigin: CLLocation?
    private var searchedAt: Date?
    private(set) var searchTask: Task<Void, Never>?
    private var searchID: UUID?
    private var cancellables = Set<AnyCancellable>()

    init(defaults: UserDefaults = .standard,
         search: @escaping (CLLocationCoordinate2D) async throws -> [SightseeingSpot] = SightseeingSearch.nearby) {
        self.defaults = defaults
        self.search = search
        isEnabled = defaults.object(forKey: "sightseeing.enabled") as? Bool ?? true
    }

    func start() {
        LocationService.shared.$location.compactMap { $0 }
            .sink { [weak self] location in
                let navigation = NavigationController.shared
                self?.update(location, now: Date(), hasActiveRoute: navigation.activeRoute != nil,
                             progress: navigation.progress, isRerouting: navigation.isRerouting)
            }
            .store(in: &cancellables)
    }

    func setConnected(_ connected: Bool, sceneID: String = "main") {
        if connected { connections.insert(sceneID) } else { connections.remove(sceneID) }
        isConnected = !connections.isEmpty
        if !isConnected { cancelSearch() }
    }

    func update(_ location: CLLocation, now: Date, hasActiveRoute: Bool,
                progress: RouteProgress?, isRerouting: Bool) {
        guard isConnected, isEnabled, SightseeingGuide.usable(location, now: now) else { return }
        // **流すだけで使い切らない。** 読むかどうかは `VoiceGuidance` が決めるので、
        // 実際に読んだと知らせが返ってきてから記録する（[didAnnounce(_:now:)]）。
        // 見送られたぶんは次の測位でまた候補に挙がる。
        if let candidate = guide.candidate(near: location, spots: spots, now: now,
                                           hasActiveRoute: hasActiveRoute,
                                           progress: progress, isRerouting: isRerouting) {
            self.notice.send(candidate)
        }

        // 位置更新ごとに問い合わせない。失敗も 1 分空け、同じ場所の成功結果は 10 分使う。
        guard searchTask == nil else { return }
        if let searchedAt, now.timeIntervalSince(searchedAt) < 60 { return }
        if let searchOrigin, let searchedAt,
           location.distance(from: searchOrigin) < 800, now.timeIntervalSince(searchedAt) < 600 { return }
        searchedAt = now
        let id = UUID()
        searchID = id
        searchTask = Task { [weak self, search] in
            do {
                let result = try await search(location.coordinate)
                guard let self, !Task.isCancelled, self.searchID == id else { return }
                self.spots = result
                self.searchOrigin = location
                self.logger.info("searched count=\(result.count)")
            } catch {
                guard let self, !Task.isCancelled, self.searchID == id else { return }
                self.searchOrigin = nil
                self.logger.info("search-failed \(error.localizedDescription, privacy: .public)")
            }
            guard let self, self.searchID == id else { return }
            self.searchTask = nil
            self.searchID = nil
            // ここでは喋らない。通信中に車が進んでいるので、次の実測位置で判定し直す。
        }
    }

    /// 読み上げた側から「実際に読んだ」と知らせてもらう。
    ///
    /// **読まれなかったひと言で施設を使い切らない**ためにここで分けている
    /// （`SightseeingGuide.candidate(near:spots:now:hasActiveRoute:progress:isRerouting:)`）。
    /// `VoiceGuidance` は読み上げ中・聞き取り中・通話中に見送るので、そのぶんは
    /// 記録も 3 分の間隔も始めない。
    func didAnnounce(_ notice: SightseeingGuide.Notice, now: Date = Date()) {
        logger.info("notice \(notice.spot.name, privacy: .public) side=\(String(describing: notice.side), privacy: .public)")
        guide.consume(notice, now: now)
    }

    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchID = nil
        spots = []
        searchOrigin = nil
        searchedAt = nil
    }
}
