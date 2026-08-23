import CoreLocation
import Foundation
import Testing
@testable import MichiNavi

/// 走った道の記録。
///
/// 守っているのは**間引きと切れ目**。どちらも外しても記録は残るので、走らせただけでは
/// 気づけない。間引きを外すと停車中の揺れが点になって距離が増え続け、切れ目を外すと
/// **走っていない直線が街をまたいで引かれる**。
@MainActor
struct TrackStoreTests {
    private func point(north: CLLocationDistance, seconds: TimeInterval) -> TrackStore.Point {
        TrackStore.Point(coordinate: SyntheticRoute.coordinate(north: north),
                         time: Date(timeIntervalSince1970: seconds))
    }

    private func fix(north: CLLocationDistance, accuracy: CLLocationAccuracy = 5) -> CLLocation {
        SyntheticRoute.fix(at: SyntheticRoute.coordinate(north: north), accuracy: accuracy)
    }

    @Test("粗い測位は記録しない")
    func poorAccuracyIsDropped() {
        #expect(TrackStore.shouldRecord(fix(north: 0, accuracy: 100), after: nil) == false)
        #expect(TrackStore.shouldRecord(fix(north: 0, accuracy: 20), after: nil))
    }

    @Test("近すぎる点は記録しない")
    func closePointsAreThinned() {
        let previous = point(north: 0, seconds: 0)
        #expect(TrackStore.shouldRecord(fix(north: 49), after: previous) == false)
        #expect(TrackStore.shouldRecord(fix(north: 51), after: previous))
    }

    @Test("離れた点は別の線にする")
    func distantPointsSplit() {
        let near = TrackStore.tracks(from: [point(north: 0, seconds: 0), point(north: 400, seconds: 10)])
        let far = TrackStore.tracks(from: [point(north: 0, seconds: 0), point(north: 600, seconds: 10)])

        #expect(near.count == 1)
        #expect(far.count == 2)
    }

    @Test("時間が空いた点は別の線にする")
    func stalePointsSplit() {
        let quick = TrackStore.tracks(from: [point(north: 0, seconds: 0), point(north: 100, seconds: 60)])
        let stale = TrackStore.tracks(from: [point(north: 0, seconds: 0), point(north: 100, seconds: 200)])

        #expect(quick.count == 1)
        #expect(stale.count == 2)
    }

    @Test("距離は点と点のあいだを足す")
    func distanceAccumulates() throws {
        let track = try #require(TrackStore.tracks(from: [point(north: 0, seconds: 0),
                                                          point(north: 100, seconds: 10),
                                                          point(north: 200, seconds: 20)]).first)
        #expect(track.coordinates.count == 3)
        #expect(abs(track.distance - 200) < 1)
    }

    /// `MKAddressRepresentations` に都道府県のプロパティが無いので、
    /// 「岐阜県大野郡白川村」から「大野郡白川村」を引いて出す。
    @Test("都道府県は市区町村を引いた残り")
    func prefectureIsTheRemainder() {
        #expect(TrackStore.prefecture(in: "東京都千代田区", city: "千代田区") == "東京都")
        #expect(TrackStore.prefecture(in: "岐阜県大野郡白川村", city: "大野郡白川村") == "岐阜県")
        #expect(TrackStore.prefecture(in: "神奈川県横浜市", city: "横浜市") == "神奈川県")
        // 英語の端末では区切りが入る。
        #expect(TrackStore.prefecture(in: "Cupertino, CA", city: "Cupertino") == "CA")
        // 都道府県にあたるものが無ければ何も返さない（呼び元が国名で埋める）。
        #expect(TrackStore.prefecture(in: "シンガポール", city: "シンガポール") == nil)
        #expect(TrackStore.prefecture(in: nil, city: "千代田区") == nil)
    }

    @Test("書いたものがそのまま読める")
    func fileRoundTrips() throws {
        let written = [point(north: 0, seconds: 1_000), point(north: 100, seconds: 1_010)]
        let data = written.map(TrackStore.encode).reduce(Data(), +)
        let read = TrackStore.decode(data)

        #expect(read == written)
    }

    /// 書いている途中で落ちると、最後の 1 件が欠けたファイルが残る。
    @Test("途中で切れたファイルでも読めるところまで読む")
    func truncatedFileIsSalvaged() {
        let data = [point(north: 0, seconds: 0), point(north: 100, seconds: 10)]
            .map(TrackStore.encode)
            .reduce(Data(), +)
            .dropLast(9)

        #expect(TrackStore.decode(Data(data)).count == 1)
    }
}
