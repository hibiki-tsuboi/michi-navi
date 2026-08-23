import CoreLocation
import Foundation

/// ある時刻・ある地点から見た太陽の位置。
///
/// **計算だけで出る**のがこの型の値打ち。`RouteWeather` は WeatherKit の
/// ケイパビリティが下りるまで黙っているし、圏外でも何も言えないが、太陽の位置は
/// 暦の計算なので、問い合わせも entitlement も要らず、山の中でも出る。
///
/// 式は NOAA の Solar Calculator と同じもの（Jean Meeus "Astronomical Algorithms" の
/// 簡略版）。**大気差は入れていない**。地平線ぎりぎりで 0.5 度ほど低く出るが、
/// 使う側のしきい値（`SunGlareAdvisor` の高度 15 度）はそこまで細かくない。
struct SolarPosition {
    /// 地平線からの角度（度）。負なら太陽は沈んでいる。
    let altitude: Double
    /// 方位（度）。**北が 0、東が 90 の時計回り。**
    ///
    /// `SunGlareAdvisor` が測る進行方位と同じ取り方にしてある。比べるための値なので、
    /// 揃っていなければ意味を持たない。
    let azimuth: Double

    static func at(_ date: Date, coordinate: CLLocationCoordinate2D) -> SolarPosition {
        // ユリウス世紀。J2000.0（2000-01-01 12:00 UTC）からの経過。
        let julianDay = date.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let t = (julianDay - 2_451_545) / 36_525

        let meanLongitude = wrapped(280.46646 + t * (36_000.76983 + t * 0.0003032), within: 360)
        let meanAnomaly = 357.52911 + t * (35_999.05029 - 0.0001537 * t)
        let eccentricity = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)

        // 中心差。円軌道からのずれ。
        let center = sin(radians(meanAnomaly)) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(radians(2 * meanAnomaly)) * (0.019993 - 0.000101 * t)
            + sin(radians(3 * meanAnomaly)) * 0.000289

        // 章動と光行差を引いた、見かけの黄経。
        let omega = 125.04 - 1_934.136 * t
        let apparentLongitude = meanLongitude + center - 0.00569 - 0.00478 * sin(radians(omega))

        let meanObliquity = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let obliquity = meanObliquity + 0.00256 * cos(radians(omega))

        let declination = asin(sin(radians(obliquity)) * sin(radians(apparentLongitude)))

        // 均時差（分）。**これが無いと南中が最大 16 分ずれる**ので、低い太陽を
        // 相手にするこの用途では効く（16 分で高度は 3〜4 度動く）。
        let y = pow(tan(radians(obliquity / 2)), 2)
        let equationOfTime = 4 * degrees(
            y * sin(2 * radians(meanLongitude))
                - 2 * eccentricity * sin(radians(meanAnomaly))
                + 4 * eccentricity * y * sin(radians(meanAnomaly)) * cos(2 * radians(meanLongitude))
                - 0.5 * y * y * sin(4 * radians(meanLongitude))
                - 1.25 * eccentricity * eccentricity * sin(2 * radians(meanAnomaly)))

        // UTC の 0 時からの分。ユリウス日は正午起点なので 0.5 足してから小数部を取る。
        let minutesOfDay = wrapped(julianDay + 0.5, within: 1) * 1_440
        // 真太陽時。経度 1 度ぶんが 4 分。
        let trueSolarTime = wrapped(minutesOfDay + equationOfTime + 4 * coordinate.longitude, within: 1_440)
        // 時角。南中で 0、午後が正。
        let hourAngle = radians(trueSolarTime / 4 - 180)

        let latitude = radians(coordinate.latitude)
        let sine = sin(latitude) * sin(declination) + cos(latitude) * cos(declination) * cos(hourAngle)

        // 方位は **atan2 で出す**。`acos` から出して時角の符号で折り返す書き方もあるが、
        // 折り返しを間違えても半日は正しく見えるので、間違いに気づけない。
        let azimuth = atan2(-sin(hourAngle) * cos(declination),
                            sin(declination) * cos(latitude) - cos(declination) * sin(latitude) * cos(hourAngle))

        return SolarPosition(altitude: degrees(asin(min(1, max(-1, sine)))),
                             azimuth: wrapped(degrees(azimuth), within: 360))
    }

    /// 2 つの方位の開き（度）。0〜180 で返る。
    static func angle(between one: Double, and other: Double) -> Double {
        let difference = wrapped(one - other, within: 360)
        return min(difference, 360 - difference)
    }

    /// 0 以上 `limit` 未満に収める。負の余りを持ち込まないため、`truncatingRemainder`
    /// をそのまま使わない。
    private static func wrapped(_ value: Double, within limit: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: limit)
        return remainder < 0 ? remainder + limit : remainder
    }

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    private static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
}
