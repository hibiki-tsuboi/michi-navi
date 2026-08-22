import Foundation
import Testing

@testable import MichiNavi

/// 到着時刻の書式。
///
/// **地域を固定しない。** `ja_JP` と `H:mm` を直に入れていたころは、英語の端末でも
/// 24 時間表記になり、利用者の 12／24 時間の設定も無視していた。日本語で見ているぶんには
/// まったく同じに見えるので、**英語の端末を触らないかぎり気づけない**。
@MainActor
struct FormattersTests {
    private let afternoon = Calendar(identifier: .gregorian)
        .date(from: DateComponents(timeZone: TimeZone(identifier: "Asia/Tokyo"),
                                   year: 2026, month: 8, day: 23, hour: 15, minute: 30))!

    private func text(_ identifier: String) -> String {
        let formatter = Formatters.arrivalFormatter(for: Locale(identifier: identifier))
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        return formatter.string(from: afternoon)
    }

    @Test("日本語では 24 時間表記のまま")
    func japaneseIsUnchanged() {
        #expect(text("ja_JP") == "15:30")
    }

    /// **ここが本題。** 地域を固定していると、英語でも 15:30 のままになる。
    /// 区切りの空白は ICU の版で変わる（narrow no-break space が入る）ので、
    /// 完全一致では見ない。
    @Test("英語（米）では 12 時間表記になる")
    func americanEnglishIsTwelveHour() {
        let american = text("en_US")
        #expect(american.hasPrefix("3:30"))
        #expect(american.contains("PM"))
    }

    /// 英語でも地域によっては 24 時間。**言語ではなく地域で決まる**ことの確認。
    @Test("英語（英）では 24 時間表記のまま")
    func britishEnglishIsTwentyFourHour() {
        #expect(text("en_GB") == "15:30")
    }
}
