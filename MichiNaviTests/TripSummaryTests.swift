import Foundation
import Testing
@testable import MichiNavi

/// ひと走りの収穫の数え方。
///
/// 守っているのは**黙る条件と、数の出どころ**。「初めて」を数える機能なので、
/// 壊れ方はどれも「たまに余計なことを言う」「たまに黙る」で、走らせただけでは
/// 気づけない。
///
///   - 初めてが 1 つも無ければ作らない（毎日の通勤で鳴らない）
///   - 数えるのは**出発時からの差**で、通算そのものではない
///   - 都道府県は入った順の 1 つ目を取る（`Set` の差では実行のたびに変わる）
///   - 空の都道府県を数えない（市区町村しか返らない国で「初めての県」が増える）
@MainActor
struct TripSummaryTests {
    private func visit(_ prefecture: String, _ city: String) -> TrackStore.Visit {
        TrackStore.Visit(prefecture: prefecture, city: city, first: Date(timeIntervalSince1970: 0))
    }

    private func mark(_ visits: [TrackStore.Visit]) -> TripSummary.Mark {
        TripSummary.Mark(prefectures: TripSummary.prefectures(in: visits), cities: visits.count)
    }

    /// 出発時から何も増えていなければ黙る。**毎日の通勤がこれ**で、
    /// ここが鳴ると「到着のたびに喋るカーナビ」になる。
    @Test func 増えていなければ何も出ない() {
        let visits = [visit("東京都", "千代田区"), visit("東京都", "港区")]
        #expect(TripSummary.harvest(since: mark(visits), visits: visits) == nil)
    }

    /// 数えるのは差。**通算をそのまま出すと、初回以外いつでも鳴る。**
    @Test func 数えるのは出発時からの差() {
        let before = [visit("東京都", "千代田区"), visit("東京都", "港区")]
        let after = before + [visit("東京都", "渋谷区")]

        let harvest = TripSummary.harvest(since: mark(before), visits: after)
        #expect(harvest?.cities == 1)
        // 通算は差ではなく全部。**貯まっていると分かるのはこちらだけ。**
        #expect(harvest?.totalCities == 3)
        // 同じ都道府県のままなら県は名乗らない。
        #expect(harvest?.prefecture == nil)
    }

    /// 都道府県が初めてなら、そちらを名乗る。市区町村の数も一緒に出る。
    @Test func 初めての都道府県を名乗る() {
        let before = [visit("東京都", "千代田区")]
        let after = before + [visit("神奈川県", "横浜市"), visit("静岡県", "熱海市")]

        let harvest = TripSummary.harvest(since: mark(before), visits: after)
        // **入った順の 1 つ目**。`Set` の差から取ると実行のたびに入れ替わる。
        #expect(harvest?.prefecture == "神奈川県")
        #expect(harvest?.cities == 2)
        #expect(harvest?.totalPrefectures == 3)
    }

    /// 市区町村は増えていないのに都道府県だけ初めて、は起こらない
    /// （県は市区町村と一緒に積まれる）。逆に**県はそのままで街だけ初めて**は普通に起きる。
    @Test func 県はそのままで街だけ初めてでも出る() {
        let before = [visit("東京都", "千代田区")]
        let after = before + [visit("東京都", "世田谷区")]

        let harvest = TripSummary.harvest(since: mark(before), visits: after)
        #expect(harvest?.prefecture == nil)
        #expect(harvest?.cities == 1)
        #expect(harvest?.totalCities == 2)
    }

    /// 空の都道府県を数えない。**市区町村しか返らない国**では `prefecture` が空になるので、
    /// 数えると「初めての都道府県に入った」が毎回成立する。
    @Test func 空の都道府県は数えない() {
        let before = [visit("", "Palo Alto")]
        let after = before + [visit("", "Mountain View")]

        let harvest = TripSummary.harvest(since: mark(before), visits: after)
        #expect(harvest?.prefecture == nil)
        #expect(harvest?.cities == 1)
        #expect(harvest?.totalPrefectures == 0)
    }

    /// 記録を消したあとに到着しても、負の数を出さない。
    @Test func 記録が消えていれば黙る() {
        let before = [visit("東京都", "千代田区"), visit("東京都", "港区")]
        #expect(TripSummary.harvest(since: mark(before), visits: []) == nil)
    }

    /// 読み上げの文。**通算が必ず入る**——これが無いと、走行中に `VisitAdvisor` が
    /// 言ったことを到着時にもう一度言うだけになる。
    @Test func 収穫の読み上げに通算が入る() {
        let city = VoicePrompt.harvest(prefecture: nil, cities: 2, totalPrefectures: 1, totalCities: 38)
        #expect(city.spokenText.contains("38"))

        // 県と街が両方初めてでも**ひと言**。県のほうを取る。
        let both = VoicePrompt.harvest(prefecture: "静岡県", cities: 2, totalPrefectures: 12, totalCities: 38)
        #expect(both.spokenText.contains("静岡県"))
        #expect(both.spokenText.contains("12"))
        #expect(!both.spokenText.contains("38"))
    }

    /// 毎日の通勤では空のカードも出さない。読み上げだけが黙り、画面に 0 件の成果が
    /// 残ると、同じ機能なのに出る条件が分かれてしまう。
    @Test func 収穫が無ければ到着カードも作らない() {
        #expect(NavigationController.ArrivalHarvest.make(destinationName: "東京駅",
                                                         harvest: nil) == nil)
    }

    /// 到着時に確定した同じ値をカードと音声が分け合えるよう、目的地と収穫を一緒に保持する。
    @Test func 到着カードは確定した収穫を保持する() throws {
        let harvest = TripSummary.Harvest(prefecture: "神奈川県",
                                          cities: 2,
                                          totalPrefectures: 3,
                                          totalCities: 12)
        let card = try #require(NavigationController.ArrivalHarvest.make(
            destinationName: "横浜赤レンガ倉庫",
            harvest: harvest
        ))

        #expect(card.destinationName == "横浜赤レンガ倉庫")
        #expect(card.harvest == harvest)
    }
}
