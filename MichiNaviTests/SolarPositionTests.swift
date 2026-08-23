import CoreLocation
import Foundation
import Testing
@testable import MichiNavi

/// 太陽の位置の計算。
///
/// **確かめられる基準が教科書にある**のがこの計算の良いところで、南中高度は
/// 「90 − 緯度 + 赤緯」、春分の日の出は真東、南中時刻は経度 1 度につき 4 分と、
/// どれも外から検算できる。`JunctionGeometry` の角度（正しさの基準がこちらに無い）
/// とはそこが違う。
///
/// 見ているのは値そのものより**符号と基準の取り方**。緯度・経度・時角のどれかを
/// 裏返しても、1 日のうち半分はもっともらしい値が出るので、走らせただけでは気づけない。
struct SolarPositionTests {
    /// 東京あたり。経度を 139 にしてあるのは、日本標準時の基準（東経 135 度）と
    /// ずらして**南中が 16 分早くなる**ことを確かめるため。
    private let tokyo = CLLocationCoordinate2D(latitude: 35.0, longitude: 139.0)
    /// 日本標準時の基準となる子午線の上。均時差だけを見たいときに使う。
    private let akashi = CLLocationCoordinate2D(latitude: 35.0, longitude: 135.0)

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day,
                                           hour: hour, minute: minute))!
    }

    /// その日いちばん高くなった瞬間（＝南中）。1 分刻みで舐める。
    private func noon(_ year: Int, _ month: Int, _ day: Int,
                      at coordinate: CLLocationCoordinate2D) -> (date: Date, sun: SolarPosition) {
        let start = date(year, month, day)
        return (0 ..< 1_440)
            .map { minute -> (date: Date, sun: SolarPosition) in
                let moment = start.addingTimeInterval(Double(minute) * 60)
                return (moment, SolarPosition.at(moment, coordinate: coordinate))
            }
            .max { $0.sun.altitude < $1.sun.altitude }!
    }

    @Test("夏至の南中高度は 90 − 緯度 + 23.4 度")
    func summerSolsticeAltitude() {
        let sun = noon(2026, 6, 21, at: tokyo).sun
        #expect(abs(sun.altitude - (90 - 35.0 + 23.44)) < 1)
    }

    @Test("冬至の南中高度は 90 − 緯度 − 23.4 度")
    func winterSolsticeAltitude() {
        let sun = noon(2026, 12, 22, at: tokyo).sun
        #expect(abs(sun.altitude - (90 - 35.0 - 23.44)) < 1)
    }

    @Test("春分の南中高度は 90 − 緯度")
    func equinoxAltitude() {
        let sun = noon(2026, 3, 20, at: tokyo).sun
        #expect(abs(sun.altitude - (90 - 35.0)) < 1)
    }

    @Test("北半球の南中は真南")
    func noonFacesSouth() {
        #expect(abs(noon(2026, 3, 20, at: tokyo).sun.azimuth - 180) < 2)
    }

    /// 緯度の符号を落とすと、これだけが落ちる（北半球の 3 つは通ってしまう）。
    @Test("南半球の南中は真北")
    func southernNoonFacesNorth() {
        let sydney = CLLocationCoordinate2D(latitude: -33.87, longitude: 151.21)
        let azimuth = noon(2026, 6, 21, at: sydney).sun.azimuth
        #expect(min(azimuth, 360 - azimuth) < 2)
    }

    @Test("真夜中の太陽は地平線の下")
    func midnightIsBelowHorizon() {
        #expect(SolarPosition.at(date(2026, 6, 21, 0, 0), coordinate: tokyo).altitude < 0)
    }

    /// 方位の符号を裏返すと、朝の太陽が西から昇る。
    @Test("春分の日の出はほぼ真東")
    func equinoxSunriseFacesEast() throws {
        let start = date(2026, 3, 20, 4, 0)
        // **`!` で開かないこと。** 経度を落とすとこの探索は空振りするので、force unwrap だと
        // テストの過程ごと落ちて、同じ実行にいるほかのテストまで巻き添えで失敗する。
        let sunrise = try #require((0 ..< 240)
            .map { start.addingTimeInterval(Double($0) * 60) }
            .first { SolarPosition.at($0, coordinate: tokyo).altitude >= 0 })
        #expect(abs(SolarPosition.at(sunrise, coordinate: tokyo).azimuth - 90) < 3)
    }

    /// 経度を落としても南中**高度**は変わらないので、上の 3 つでは気づけない。
    @Test("東にあるほど南中が早い（経度 1 度で 4 分）")
    func longitudeShiftsNoon() {
        let east = noon(2026, 3, 20, at: tokyo).date
        let west = noon(2026, 3, 20, at: akashi).date
        #expect(abs(west.timeIntervalSince(east) - 16 * 60) < 2 * 60)
    }

    /// 均時差を落とすと、どちらもちょうど 12:00 になって落ちる。
    @Test("南中は 2 月上旬に遅れ、11 月上旬に早まる")
    func equationOfTimeMovesNoon() {
        let february = noon(2026, 2, 11, at: akashi).date
        let november = noon(2026, 11, 3, at: akashi).date

        #expect(abs(february.timeIntervalSince(date(2026, 2, 11, 12, 14))) < 5 * 60)
        #expect(abs(november.timeIntervalSince(date(2026, 11, 3, 11, 44))) < 5 * 60)
    }

    @Test("方位の開きは 0〜180 度で返る")
    func angleFolds() {
        #expect(abs(SolarPosition.angle(between: 10, and: 350) - 20) < 0.001)
        #expect(abs(SolarPosition.angle(between: 350, and: 10) - 20) < 0.001)
        #expect(abs(SolarPosition.angle(between: 0, and: 200) - 160) < 0.001)
    }
}
