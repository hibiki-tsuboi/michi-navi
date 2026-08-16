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

    private static let arrivalTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "H:mm"
        return formatter
    }()

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
