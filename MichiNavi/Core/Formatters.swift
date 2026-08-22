import Foundation
import MapKit

/// 距離・時間・到着時刻の表示を 1 か所にまとめる。
/// iPhone 画面と CarPlay 画面で表記がずれないようにするため。
enum Formatters {
    static let distance: MKDistanceFormatter = {
        let formatter = MKDistanceFormatter()
        formatter.unitStyle = .abbreviated
        formatter.units = .metric
        return formatter
    }()

    private static let duration: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    private static let arrivalTime = arrivalFormatter(for: .current)

    /// 到着時刻の書式。
    ///
    /// **地域を固定しないこと。** 2026-08-23 まで `ja_JP` と `H:mm` を直に入れていたので、
    /// **英語の端末でも 24 時間表記になり、利用者の 12／24 時間の設定も無視していた**
    /// （実測: en_US は本来 `3:30 PM`）。ここは両画面で表記を揃えるための場所なのに、
    /// 距離（`MKDistanceFormatter`）と所要（`DateComponentsFormatter`）が地域に従う中で
    /// ここだけ日本に寄っていた。`timeStyle = .short` なら日本語での見え方
    /// （`15:30`）は変わらない。
    ///
    /// 地域を引数で受けるのは**テストから触るため**。固定に戻したときに落ちるように
    /// しておかないと、英語の端末でしか症状が出ないので気づけない。
    static func arrivalFormatter(for locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }

    static func distanceText(_ meters: CLLocationDistance) -> String {
        distance.string(fromDistance: meters)
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        // 1 分未満を「0分」ではなく「まもなく」にする。
        guard seconds >= 60 else { return String(localized: "まもなく") }
        return duration.string(from: seconds) ?? "—"
    }

    static func arrivalText(_ date: Date) -> String {
        arrivalTime.string(from: date)
    }

    /// 読み上げ用の距離。「300メートル」「1.5キロ」。
    /// `distanceText` の "300 m" は読み上げると不自然になるため別に用意する。
    static func spokenDistance(_ meters: CLLocationDistance) -> String {
        guard meters >= 1000 else { return String(localized: "\(Int(meters.rounded()))メートル") }

        let kilometers = meters / 1000
        // ちょうど 1km は「1.0キロ」ではなく「1キロ」と読ませる。
        guard kilometers != kilometers.rounded() else { return String(localized: "\(Int(kilometers))キロ") }
        return String(format: String(localized: "%.1fキロ"), kilometers)
    }

    /// 「12 km・24分・15:30 着」のような 1 行サマリー。
    static func routeSummary(distance meters: CLLocationDistance, duration seconds: TimeInterval) -> String {
        let arrival = arrivalText(Date(timeIntervalSinceNow: seconds))
        return String(localized: "\(distanceText(meters))・\(durationText(seconds))・\(arrival) 着")
    }
}
