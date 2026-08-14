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
        guard seconds >= 60 else { return "まもなく" }
        return duration.string(from: seconds) ?? "—"
    }

    static func arrivalText(_ date: Date) -> String {
        arrivalTime.string(from: date)
    }

    /// 「12 km・24分・15:30 着」のような 1 行サマリー。
    static func routeSummary(distance meters: CLLocationDistance, duration seconds: TimeInterval) -> String {
        let arrival = arrivalText(Date(timeIntervalSinceNow: seconds))
        return "\(distanceText(meters))・\(durationText(seconds))・\(arrival) 着"
    }
}
