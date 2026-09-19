import Combine
import Foundation

@MainActor
final class BackupService: ObservableObject {
    static let shared = BackupService()

    @Published private(set) var isBusy = false
    private(set) var isRestoring = false
    private let defaults: UserDefaults
    private let tracks: TrackStore
    private let reload: @MainActor () -> Void
    private let canRestore: @MainActor () -> Bool

    init(defaults: UserDefaults = .standard, tracks: TrackStore? = nil,
         canRestore: @escaping @MainActor () -> Bool = {
             NavigationController.shared.phase == .idle
                 && NavigationController.shared.activeRoute == nil
                 && !SightseeingAdvisor.shared.isConnected
         }, reload: @escaping @MainActor () -> Void = {
             DestinationStore.shared.reload()
             RoutePreferences.shared.reload()
             VisitAdvisor.shared.reload()
             SightseeingAdvisor.shared.reload()
             NavigationController.shared.dismissArrivalHarvest()
         }) {
        self.defaults = defaults
        self.tracks = tracks ?? .shared
        self.canRestore = canRestore
        self.reload = reload
    }

    func export() async throws -> Data {
        guard !isBusy else { throw BackupError.busy }
        isBusy = true
        defer { isBusy = false }
        let data = try await tracks.backupData()
        let archive = try snapshot(trackData: data)
        return try await Task.detached { try archive.encoded() }.value
    }

    func restore(_ archive: BackupArchive) async throws {
        guard !isBusy else { throw BackupError.busy }
        guard canRestore() else { throw BackupError.navigationInProgress }
        isBusy = true
        isRestoring = true
        defer { isBusy = false; isRestoring = false }

        try await Task.detached { try archive.validate() }.value
        // 失敗し得る変換は書き換える前に済ませる。ファイル保存後は同期的に反映する。
        let values = try preferenceValues(for: archive)
        let visits = archive.visits.map {
            TrackStore.Visit(prefecture: $0.prefecture, city: $0.city, first: $0.first)
        }
        try await tracks.replaceFromBackup(archive.tracks, visits: visits,
                                            isRecording: archive.settings.isRecording,
                                            canCommit: canRestore) {
            for (key, value) in values {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            reload()
        }
    }

    private func snapshot(trackData: Data) throws -> BackupArchive {
        func value<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
            guard defaults.object(forKey: key) != nil else { return nil }
            guard let data = defaults.data(forKey: key) else { throw BackupError.invalidFile }
            return try JSONDecoder().decode(type, from: data)
        }
        return try BackupArchive(
            tracks: trackData,
            visits: value("tracks.visits", as: [BackupArchive.Visit].self) ?? [],
            destinations: .init(
                recents: value("destinations.recents", as: [BackupArchive.SavedPlace].self) ?? [],
                favorites: value("destinations.favorites", as: [BackupArchive.SavedPlace].self) ?? [],
                home: value("destinations.pinned.home", as: BackupArchive.SavedPlace.self),
                work: value("destinations.pinned.work", as: BackupArchive.SavedPlace.self),
                parking: value("destinations.parking", as: BackupArchive.Parking.self)),
            settings: .init(
                isRecording: defaults.object(forKey: "tracks.recording") as? Bool ?? true,
                announcesVisits: defaults.object(forKey: "visit.announce") as? Bool ?? true,
                sightseeingEnabled: defaults.object(forKey: "sightseeing.enabled") as? Bool ?? true,
                avoidsTolls: defaults.bool(forKey: "route.avoidsTolls"),
                avoidsHighways: defaults.bool(forKey: "route.avoidsHighways"),
                vehicleRange: defaults.double(forKey: "route.vehicleRange"),
                refuelKind: defaults.string(forKey: "route.refuelKind") ?? "gasStation",
                mapOrientation: defaults.string(forKey: "map.orientation") ?? "heading"))
    }

    private func preferenceValues(for archive: BackupArchive) throws -> [(String, Any?)] {
        let encoder = JSONEncoder()
        let destinations = archive.destinations
        let settings = archive.settings
        return try [
            ("destinations.recents", encoder.encode(destinations.recents)),
            ("destinations.favorites", encoder.encode(destinations.favorites)),
            ("destinations.pinned.home", destinations.home.map { try encoder.encode($0) }),
            ("destinations.pinned.work", destinations.work.map { try encoder.encode($0) }),
            ("destinations.parking", destinations.parking.map { try encoder.encode($0) }),
            ("tracks.visits", encoder.encode(archive.visits)),
            ("tracks.recording", settings.isRecording),
            ("visit.announce", settings.announcesVisits),
            ("sightseeing.enabled", settings.sightseeingEnabled),
            ("route.avoidsTolls", settings.avoidsTolls),
            ("route.avoidsHighways", settings.avoidsHighways),
            ("route.vehicleRange", settings.vehicleRange),
            ("route.refuelKind", settings.refuelKind),
            ("map.orientation", settings.mapOrientation)
        ]
    }
}

/// ファイルプロバイダのダウンロードを待ってから読む。大きなファイルもメインを止めない。
nonisolated enum BackupFiles {
    static func read(_ url: URL) throws -> BackupArchive {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<BackupArchive, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            result = Result {
                let handle = try FileHandle(forReadingFrom: readable)
                defer { try? handle.close() }
                var data = Data()
                while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
                    guard data.count + chunk.count <= BackupArchive.maximumFileSize else {
                        throw BackupError.tooLarge
                    }
                    data.append(chunk)
                }
                return try BackupArchive.decode(data)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw BackupError.invalidFile }
        return try result.get()
    }

    static func prepareExport(_ data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MichiNaviBackup-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = directory.appending(path: "TsuboNavi-backup-\(formatter.string(from: Date())).json")
        do { try data.write(to: url, options: .atomic) }
        catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return url
    }

    static func removeExport(_ url: URL) {
        // 削除先は自分が作った一時フォルダに限る。
        let directory = url.deletingLastPathComponent()
        guard directory.lastPathComponent.hasPrefix("MichiNaviBackup-"),
              directory.deletingLastPathComponent().standardizedFileURL
                == FileManager.default.temporaryDirectory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
