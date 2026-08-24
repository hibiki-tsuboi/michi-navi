import Combine
import Foundation
import Testing
@testable import MichiNavi

/// 県境と初めての街の知らせ方。
///
/// 守っているのは**黙る条件のほう**。3 つあって、どれを外しても「たまに鳴る機能」には
/// なるので、走らせただけでは壊れたことに気づけない。
///
///   - 起動直後は県境を言わない（前に居た土地を知らないので、またいだとは言えない）
///   - 同じ都道府県のまま初めての街が続いたら間隔を空ける（都心は数キロごとに変わる）
///   - 県境のほうは間隔で抑えない（続けて起きないので、抑えると 1 件が落ちるだけ）
@MainActor
struct VisitAdvisorTests {
    private func located(_ prefecture: String, _ city: String, first: Bool = false) -> TrackStore.Located {
        TrackStore.Located(prefecture: prefecture, city: city, isFirst: first)
    }

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func notice(_ located: TrackStore.Located,
                        previous: String?,
                        lastNoticed: Date? = nil) -> VisitAdvisor.Notice? {
        VisitAdvisor.notice(for: located, previousPrefecture: previous, lastNoticed: lastNoticed, now: now)
    }

    // MARK: - 県境

    @Test("起動直後は県境を言わない")
    func noBaselineIsSilent() {
        // 前に居た土地を知らないので、言えるのは「いまここにいる」まで。
        #expect(notice(located("岐阜県", "高山市"), previous: nil) == nil)
    }

    @Test("都道府県をまたいだら言う")
    func crossingIsAnnounced() {
        #expect(notice(located("岐阜県", "高山市"), previous: "長野県")
                == .prefecture(name: "岐阜県", firstCity: nil))
    }

    @Test("同じ都道府県のままなら黙る")
    func sameGroundIsSilent() {
        // 市区町村は変わっているが、初めてではない。
        #expect(notice(located("岐阜県", "郡上市"), previous: "岐阜県") == nil)
    }

    @Test("都道府県が空なら県境と数えない")
    func emptyPrefectureIsNotCrossing() {
        // 市区町村しか返らない国では空になる。またいだ扱いにすると国外で鳴り続ける。
        #expect(notice(located("", "Singapore"), previous: "東京都") == nil)
    }

    // MARK: - 初めての街

    @Test("初めての市区町村は言う")
    func firstCityIsAnnounced() {
        #expect(notice(located("岐阜県", "大野郡白川村", first: true), previous: "岐阜県")
                == .firstCity(name: "大野郡白川村"))
    }

    @Test("県境と初めての街が重なったらひと言にまとめる")
    func crossingIntoFirstCity() {
        // 2 つ流すと、2 つ目は 1 つ目の余韻に埋まる。
        #expect(notice(located("岐阜県", "大野郡白川村", first: true), previous: "富山県")
                == .prefecture(name: "岐阜県", firstCity: "大野郡白川村"))
    }

    @Test("初めての市区町村が続いたら間隔を空ける")
    func firstCitiesAreSpaced() {
        // 初めて東京を横断すると区の数だけ鳴る。抑えないと 15km で 4 回。
        let city = located("東京都", "港区", first: true)
        #expect(notice(city, previous: "東京都",
                       lastNoticed: now.addingTimeInterval(-VisitAdvisor.minimumInterval + 60)) == nil)
        #expect(notice(city, previous: "東京都",
                       lastNoticed: now.addingTimeInterval(-VisitAdvisor.minimumInterval - 60)) != nil)
    }

    @Test("県境は間隔で抑えない")
    func crossingIgnoresInterval() {
        // 三県境のように短い区間で 2 度またぐことがある。いちばん言いたい 1 件を落とさない。
        #expect(notice(located("群馬県", "みなかみ町"), previous: "新潟県",
                       lastNoticed: now.addingTimeInterval(-1)) != nil)
    }

    // MARK: - 初めてかどうかの判定（`TrackStore`）

    @Test("同じ市区町村を 2 度引いても初めては 1 度だけ")
    func repeatedCityIsNotFirst() throws {
        let suite = "VisitAdvisorTests"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = TrackStore(defaults: defaults)

        var received: [TrackStore.Located] = []
        let subscription = store.located.sink { received.append($0) }
        defer { subscription.cancel() }

        let visit = TrackStore.Visit(prefecture: "岐阜県", city: "大野郡白川村", first: now)
        store.remember(visit)
        store.remember(TrackStore.Visit(prefecture: "岐阜県", city: "大野郡白川村", first: now))

        // **2 度目も流す。** 流さないと、同じ街に留まったまま県境をまたいだ次の 1 件で
        // 比べる相手が無くなる。
        #expect(received.map(\.isFirst) == [true, false])
        #expect(store.visits.count == 1)

        defaults.removePersistentDomain(forName: suite)
    }
}
