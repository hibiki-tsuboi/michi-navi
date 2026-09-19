import CoreLocation
import Foundation
import Testing
@testable import MichiNavi

@MainActor
struct BackupTests {
    @MainActor
    private struct Fixture {
        let suite = "BackupTests.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let defaults: UserDefaults
        let tracks: TrackStore
        let destinations: DestinationStore
        let preferences: RoutePreferences
        let visits: VisitAdvisor
        let sightseeing: SightseeingAdvisor
        let service: BackupService

        var fileURL: URL { directory.appending(path: "tracks.bin") }

        init(canRestore: @escaping @MainActor () -> Bool = { true }) throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            tracks = TrackStore(defaults: defaults, fileURL: directory.appending(path: "tracks.bin"))
            destinations = DestinationStore(defaults: defaults)
            preferences = RoutePreferences(defaults: defaults)
            visits = VisitAdvisor(defaults: defaults)
            sightseeing = SightseeingAdvisor(defaults: defaults)
            let destinations = self.destinations
            let preferences = self.preferences
            let visits = self.visits
            let sightseeing = self.sightseeing
            service = BackupService(defaults: defaults, tracks: tracks, canRestore: canRestore) {
                destinations.reload()
                preferences.reload()
                visits.reload()
                sightseeing.reload()
            }
        }

        func clean() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func example() -> BackupArchive {
        let points = [0.0, 100, 200].enumerated().map { index, north in
            TrackStore.Point(coordinate: SyntheticRoute.coordinate(north: north),
                             time: Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 10)))
        }
        let place = BackupArchive.SavedPlace(id: "place-1", name: "公園", subtitle: "横浜市",
                                             latitude: 35.45, longitude: 139.63)
        return BackupArchive(
            tracks: points.map(TrackStore.encode).reduce(Data(), +),
            visits: [.init(prefecture: "神奈川県", city: "横浜市", first: points[0].time)],
            destinations: .init(recents: [place], favorites: [place], home: place, work: place,
                                parking: .init(place: place, date: points[0].time)),
            settings: .init(isRecording: false, announcesVisits: false, sightseeingEnabled: false,
                            avoidsTolls: true, avoidsHighways: true, vehicleRange: 350_000,
                            refuelKind: "evCharger", mapOrientation: "north"))
    }

    @Test("別の保存領域へ全データを移し、その場の画面と次回起動の値を揃える")
    func migrationRoundTripsAllData() async throws {
        let source = try Fixture()
        let destination = try Fixture()
        defer { source.clean(); destination.clean() }
        let original = example()
        try await source.service.restore(original)
        // 移行対象外の OS 設定は持ち出さず、復元先の値も消さない。
        source.defaults.set("source-private", forKey: "unrelated.preference")
        destination.defaults.set("keep-me", forKey: "unrelated.preference")
        let exported = try await source.service.export()
        #expect(!String(decoding: exported, as: UTF8.self).contains("source-private"))
        let archive = try BackupArchive.decode(exported)
        try await destination.service.restore(archive)

        #expect(try Data(contentsOf: destination.fileURL) == original.tracks)
        #expect(destination.tracks.tracks.count == 1)
        #expect(destination.tracks.tracks.first?.coordinates.count == 3)
        #expect(destination.tracks.totalDistance > 190)
        #expect(destination.tracks.visits.first?.city == "横浜市")
        #expect(destination.tracks.isRecording == false)
        #expect(destination.destinations.home?.id == "place-1")
        #expect(destination.destinations.work?.name == "公園")
        #expect(destination.destinations.parking?.date == original.destinations.parking?.date)
        #expect(destination.destinations.favorites.count == 1)
        #expect(destination.destinations.recents.count == 1)
        #expect(destination.preferences.avoidsTolls && destination.preferences.avoidsHighways)
        #expect(destination.preferences.vehicleRange == 350_000)
        #expect(destination.preferences.refuelKind == .evCharger)
        #expect(!destination.visits.isEnabled && !destination.sightseeing.isEnabled)
        #expect(destination.defaults.string(forKey: "map.orientation") == "north")
        #expect(destination.defaults.string(forKey: "unrelated.preference") == "keep-me")
        #expect(DestinationStore(defaults: destination.defaults).home?.id == "place-1")
        #expect(RoutePreferences(defaults: destination.defaults).vehicleRange == 350_000)
        #expect(TrackStore(defaults: destination.defaults, fileURL: destination.fileURL).visits.count == 1)
        let reexported = try BackupArchive.decode(await destination.service.export())
        #expect(reexported.tracks == original.tracks)
        #expect(reexported.visits == original.visits)
        #expect(reexported.destinations == original.destinations)
        #expect(reexported.settings == original.settings)
    }

    @Test("空のバックアップも正しく書き出し、古いピンや記録を残さず置き換える")
    func emptyBackupReplacesExistingData() async throws {
        let source = try Fixture()
        let destination = try Fixture()
        defer { source.clean(); destination.clean() }
        let empty = try BackupArchive.decode(await source.service.export())
        #expect(empty.pointCount == 0)
        #expect(empty.settings.isRecording && empty.settings.announcesVisits && empty.settings.sightseeingEnabled)
        try await destination.service.restore(example())
        try await destination.service.restore(empty)
        #expect(try Data(contentsOf: destination.fileURL).isEmpty)
        #expect(destination.tracks.tracks.isEmpty && destination.tracks.visits.isEmpty)
        #expect(destination.destinations.home == nil && destination.destinations.work == nil)
        #expect(destination.destinations.parking == nil && destination.destinations.favorites.isEmpty)
        #expect(destination.defaults.object(forKey: "destinations.pinned.home") == nil)
    }

    @Test("壊れた座標・時刻・切れた記録・設定・重複を復元前に拒否する", arguments: 0 ..< 7)
    func invalidBackupPreservesExistingData(kind: Int) async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let original = example()
        try await fixture.service.restore(original)
        var invalid = original
        switch kind {
        case 0: invalid.tracks.removeLast()
        case 1:
            invalid.tracks = TrackStore.encode(.init(coordinate: .init(latitude: 91, longitude: 139), time: Date()))
        case 2:
            invalid.tracks = TrackStore.encode(.init(coordinate: .init(latitude: 35, longitude: 139),
                                                     time: Date(timeIntervalSince1970: .infinity)))
        case 3: invalid.destinations.home?.longitude = -181
        case 4: invalid.settings.vehicleRange = -1
        case 5: invalid.settings.refuelKind = "unknown"
        default: invalid.visits.append(invalid.visits[0])
        }
        await #expect(throws: BackupError.self) { try await fixture.service.restore(invalid) }
        #expect(try Data(contentsOf: fixture.fileURL) == original.tracks)
        #expect(fixture.destinations.home?.coordinate.longitude == 139.63)
        #expect(fixture.tracks.visits.count == 1)
        #expect(fixture.preferences.vehicleRange == 350_000)
        #expect(!fixture.service.isBusy && !fixture.service.isRestoring && !fixture.tracks.isTransferring)
    }

    @Test("他のJSONと未対応版は、既存データに触れず読み込み段階で拒否する")
    func rejectsForeignAndNewerFiles() throws {
        #expect(throws: BackupError.self) { try BackupArchive.decode(Data("{}".utf8)) }
        #expect(throws: BackupError.self) { try BackupArchive.decode(Data("not json".utf8)) }
        let newer = Data(#"{"format":"jp.hibiki.michinavi.backup","version":99}"#.utf8)
        do {
            _ = try BackupArchive.decode(newer)
            Issue.record("新しい版を取り込んだ")
        } catch BackupError.unsupportedVersion {} // 版の確認が本文の decode より先に来ること。
        var foreign = example()
        foreign.format = "other.app"
        #expect(throws: BackupError.self) { try BackupArchive.decode(JSONEncoder().encode(foreign)) }
    }

    @Test("ファイル保存に失敗したとき、設定と表示を変更しない")
    func writeFailureDoesNotCommitPreferences() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        // ファイルと同じ名前のディレクトリを置き、atomic 書き込みを確実に失敗させる。
        try FileManager.default.createDirectory(at: fixture.fileURL, withIntermediateDirectories: true)
        let sentinel = fixture.fileURL.appending(path: "existing-data")
        try Data("keep".utf8).write(to: sentinel)
        fixture.tracks.remember(.init(prefecture: "東京都", city: "千代田区", first: Date()))
        await #expect(throws: (any Error).self) { try await fixture.service.restore(example()) }
        #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
        #expect(fixture.destinations.home == nil)
        #expect(fixture.preferences.vehicleRange == 0)
        #expect(fixture.tracks.visits.first?.city == "千代田区")
        #expect(fixture.defaults.object(forKey: "destinations.favorites") == nil)
        #expect(!fixture.service.isBusy && !fixture.tracks.isTransferring)
    }

    @Test("先行する消去が、復元したファイルをあとから消さない")
    func queuedClearFinishesBeforeImport() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try await fixture.service.restore(example())
        fixture.tracks.clear()
        try await fixture.service.restore(example())
        #expect(try await fixture.tracks.backupData() == example().tracks)
        #expect(fixture.tracks.visits.count == 1)
    }

    @Test("確認画面のあとに案内が始まった場合も復元を拒否する")
    func checksNavigationAtCommit() async throws {
        var checks = 0
        let fixture = try Fixture(canRestore: { checks += 1; return checks == 1 })
        defer { fixture.clean() }
        await #expect(throws: BackupError.self) { try await fixture.service.restore(example()) }
        #expect(checks == 2)
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
        #expect(fixture.defaults.object(forKey: "destinations.favorites") == nil)
    }

    @Test("復元直後に同じ位置を受け取っても走行記録を重複させない")
    func importPreservesTheRecordingTail() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        var archive = example()
        archive.settings.isRecording = true
        try await fixture.service.restore(archive)
        let last = try #require(TrackStore.decode(archive.tracks).last)
        fixture.tracks.handle(location: CLLocation(coordinate: last.coordinate, altitude: 0,
                                                    horizontalAccuracy: 5, verticalAccuracy: 5,
                                                    timestamp: last.time.addingTimeInterval(10)))
        #expect(try await fixture.tracks.backupData() == archive.tracks)
        #expect(fixture.tracks.tracks.count == 1)
        #expect(fixture.tracks.tracks.first?.coordinates.count == 3)
    }

    @Test("書き出した実ファイルを読み込み、共有後は自分の一時ファイルだけを消す")
    func sharedFileRoundTrips() throws {
        let original = example()
        let url = try BackupFiles.prepareExport(original.encoded())
        defer { BackupFiles.removeExport(url) }
        #expect(try BackupFiles.read(url) == original)
        #expect(url.pathExtension == "json")
        BackupFiles.removeExport(url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
