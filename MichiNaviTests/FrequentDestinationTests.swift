import Foundation
import Testing
@testable import MichiNavi

/// 「いまの時間帯によく行く場所」の選び方。
///
/// **`DestinationStore.shared` は使わない。** `init(defaults:)` に捨て `UserDefaults` を
/// 渡して、履歴と訪問時刻を直に置く。訪問時刻は `remember(_:)` からは `Date()` でしか
/// 入らないので、**保存済みの状態から読ませるのがいまの唯一の注入口**。
@MainActor
struct FrequentDestinationTests {
    private let calendar = Calendar.current

    /// 2026-08-17 は月曜。曜日は「平日か休日か」でしか見ないので、
    /// 平日は月曜、休日は土曜（2026-08-15）で代表させる。
    private func date(weekday: Weekday, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8,
                                           day: weekday == .weekday ? 17 : 15,
                                           hour: hour, minute: minute))!
    }

    private enum Weekday { case weekday, weekend }

    private func makeStore(recents: [Place], visits: [String: [Date]]) -> DestinationStore {
        let defaults = UserDefaults(suiteName: "MichiNaviTests.\(UUID().uuidString)")!
        defaults.set(try? JSONEncoder().encode(recents), forKey: "destinations.recents")
        defaults.set(try? JSONEncoder().encode(visits), forKey: "destinations.visits")
        return DestinationStore(defaults: defaults)
    }

    private func place(_ name: String) -> Place {
        SyntheticRoute.place(name, at: SyntheticRoute.coordinate(north: 0))
    }

    @Test("同じ時間帯に 2 回以上行っていれば引き上げる")
    func liftsRepeatedVisits() {
        let nursery = place("保育園")
        let store = makeStore(recents: [nursery],
                              visits: [nursery.id: [date(weekday: .weekday, hour: 8, minute: 10),
                                                    date(weekday: .weekday, hour: 8, minute: 40)]])

        #expect(store.frequentDestinations(at: date(weekday: .weekday, hour: 8, minute: 30)) == [nursery])
    }

    @Test("1 回では引き上げない（たまたま寄った場所を先頭に出さない）")
    func doesNotLiftSingleVisit() {
        let shop = place("たまたま寄った店")
        let store = makeStore(recents: [shop],
                              visits: [shop.id: [date(weekday: .weekday, hour: 8, minute: 10)]])

        #expect(store.frequentDestinations(at: date(weekday: .weekday, hour: 8, minute: 30)).isEmpty)
    }

    @Test("時間帯が離れていれば引き上げない")
    func ignoresDifferentTimeOfDay() {
        let office = place("職場")
        let store = makeStore(recents: [office],
                              visits: [office.id: [date(weekday: .weekday, hour: 8, minute: 0),
                                                   date(weekday: .weekday, hour: 8, minute: 30)]])

        // 昼に見れば「この時間の行き先」ではない。
        #expect(store.frequentDestinations(at: date(weekday: .weekday, hour: 13, minute: 0)).isEmpty)
    }

    @Test("時刻の比較は分まで見る（時の成分だけで比べない）")
    func comparesMinutesNotHours() {
        // 23:30 と 21:00 は「23 と 21 で 2 時間差」ではなく 2 時間半差。
        // 時の成分だけで比べると窓が実質 3 時間近くまで広がる。
        let bath = place("銭湯")
        let store = makeStore(recents: [bath],
                              visits: [bath.id: [date(weekday: .weekday, hour: 23, minute: 30),
                                                 date(weekday: .weekday, hour: 23, minute: 40)]])

        #expect(store.frequentDestinations(at: date(weekday: .weekday, hour: 21, minute: 0)).isEmpty)
    }

    @Test("日付をまたぐ時刻は近いものとして扱う（時計は 24 時間で一周する）")
    func wrapsAroundMidnight() {
        // 23:30 と 0:30 は 1 時間差。日付は見ない（「毎日この時刻」を拾いたいので）。
        let convenience = place("深夜のコンビニ")
        let store = makeStore(recents: [convenience],
                              visits: [convenience.id: [date(weekday: .weekday, hour: 23, minute: 30),
                                                        date(weekday: .weekday, hour: 23, minute: 50)]])

        #expect(store.frequentDestinations(at: date(weekday: .weekday, hour: 0, minute: 30)) == [convenience])
    }

    @Test("平日と休日は混ぜない")
    func separatesWeekdaysFromWeekends() {
        let office = place("職場")
        let store = makeStore(recents: [office],
                              visits: [office.id: [date(weekday: .weekday, hour: 8, minute: 10),
                                                   date(weekday: .weekday, hour: 8, minute: 30)]])

        #expect(store.frequentDestinations(at: date(weekday: .weekend, hour: 8, minute: 20)).isEmpty)
    }

    @Test("履歴に無い場所は引き上げない（消した行き先が並べ替えにだけ効かないように）")
    func onlyLiftsPlacesStillInHistory() {
        let deleted = place("消した行き先")
        let store = makeStore(recents: [],
                              visits: [deleted.id: [date(weekday: .weekday, hour: 8, minute: 10),
                                                    date(weekday: .weekday, hour: 8, minute: 30)]])

        #expect(store.frequentDestinations(at: date(weekday: .weekday, hour: 8, minute: 20)).isEmpty)
    }
}
