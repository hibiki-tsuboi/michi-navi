import Foundation

/// 端末や MapKit のオブジェクトに依存しない移行形式。設定領域を丸ごと持ち出さない。
nonisolated struct BackupArchive: Codable, Sendable, Equatable {
    static let maximumFileSize = 128 * 1_024 * 1_024
    var format = "jp.hibiki.michinavi.backup"
    var version = 1
    var createdAt = Date()
    var tracks: Data
    var visits: [Visit]
    var destinations: Destinations
    var settings: Settings

    struct Visit: Codable, Sendable, Equatable {
        var prefecture: String
        var city: String
        var first: Date
    }

    // Place の保存形式と揃える。復元前に座標を検査でき、バックグラウンドでも扱える。
    struct SavedPlace: Codable, Sendable, Equatable {
        var id: String
        var name: String
        var subtitle: String
        var latitude: Double
        var longitude: Double
    }

    struct Parking: Codable, Sendable, Equatable {
        var place: SavedPlace
        var date: Date
    }

    struct Destinations: Codable, Sendable, Equatable {
        var recents: [SavedPlace]
        var favorites: [SavedPlace]
        var home: SavedPlace?
        var work: SavedPlace?
        var parking: Parking?
    }

    struct Settings: Codable, Sendable, Equatable {
        var isRecording: Bool
        var announcesVisits: Bool
        var sightseeingEnabled: Bool
        var avoidsTolls: Bool
        var avoidsHighways: Bool
        var vehicleRange: Double
        var refuelKind: String
        var mapOrientation: String
        /// 音声案内を消しているか。**任意項目**にして、この項目が無かったころの
        /// バックアップも同じ版のまま読めるようにしてある（無ければ鳴らす）。
        var voiceMuted: Bool? = nil
    }

    var pointCount: Int { tracks.count / 24 }

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumFileSize else { throw BackupError.tooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumFileSize else { throw BackupError.tooLarge }
        // 新しい版の必須項目が違っていても「壊れたファイル」ではなく更新を案内する。
        struct Header: Decodable { let format: String; let version: Int }
        do {
            let header = try JSONDecoder().decode(Header.self, from: data)
            guard header.format == "jp.hibiki.michinavi.backup" else { throw BackupError.invalidFile }
            guard header.version == 1 else { throw BackupError.unsupportedVersion }
            let archive = try JSONDecoder().decode(Self.self, from: data)
            try archive.validate()
            return archive
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.invalidFile
        }
    }

    func validate() throws {
        guard format == "jp.hibiki.michinavi.backup" else { throw BackupError.invalidFile }
        guard version == 1 else { throw BackupError.unsupportedVersion }
        guard Self.validDate(createdAt), tracks.count <= Self.maximumFileSize,
              tracks.count.isMultiple(of: 24) else { throw BackupError.invalidFile }

        // 通常起動時の救済用 decoder と違い、移行では壊れた点を黙って捨てない。
        let validTracks = tracks.withUnsafeBytes { raw in
            for offset in stride(from: 0, to: raw.count, by: 24) {
                func number(_ slot: Int) -> Double {
                    Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(
                        fromByteOffset: offset + slot * 8, as: UInt64.self)))
                }
                guard Self.validCoordinate(latitude: number(0), longitude: number(1)),
                      Self.validDate(Date(timeIntervalSince1970: number(2))) else { return false }
            }
            return true
        }
        guard validTracks, settings.vehicleRange.isFinite, settings.vehicleRange >= 0,
              ["gasStation", "evCharger"].contains(settings.refuelKind),
              ["heading", "north"].contains(settings.mapOrientation),
              destinations.recents.count <= 20 else { throw BackupError.invalidFile }

        let places = destinations.recents + destinations.favorites
            + [destinations.home, destinations.work, destinations.parking?.place].compactMap { $0 }
        guard places.allSatisfy({
            !$0.id.isEmpty && !$0.name.isEmpty
                && Self.validCoordinate(latitude: $0.latitude, longitude: $0.longitude)
        }), visits.allSatisfy({ !$0.city.isEmpty && Self.validDate($0.first) }),
        Set(visits.map { "\($0.prefecture)/\($0.city)" }).count == visits.count,
        Set(destinations.recents.map(\.id)).count == destinations.recents.count,
        Set(destinations.favorites.map(\.id)).count == destinations.favorites.count,
        destinations.parking.map({ Self.validDate($0.date) }) ?? true else {
            throw BackupError.invalidFile
        }
    }

    private static func validCoordinate(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite
            && (-90 ... 90).contains(latitude) && (-180 ... 180).contains(longitude)
    }

    private static func validDate(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && (-62_135_596_800 ... 253_402_300_799).contains(seconds)
    }
}

nonisolated enum BackupError: Error, LocalizedError {
    case invalidFile, unsupportedVersion, tooLarge, busy, navigationInProgress

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            String(localized: "バックアップを読み取れません。つぼナビで書き出したファイルを選んでください。")
        case .unsupportedVersion:
            String(localized: "このバックアップの形式には対応していません。つぼナビを最新版に更新してください。")
        case .tooLarge:
            String(localized: "バックアップのサイズが上限の128MBを超えています。")
        case .busy:
            String(localized: "バックアップの処理中です。完了してからもう一度お試しください。")
        case .navigationInProgress:
            String(localized: "読み込みは案内を終了し、CarPlayとの接続を解除してから行ってください。")
        }
    }
}
