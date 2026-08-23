import CoreLocation
import Foundation
import Testing
@testable import MichiNavi

/// 正面から低い太陽が入る区間の見つけ方。
///
/// 守っているのは 3 つの条件の**効かせ方**——低いこと・正面にあること・
/// しばらく続くこと。どれを外しても「たまに出る助言」にはなるので、走らせただけでは
/// 壊れたことに気づけない。とくに方位は、裏返しても半分の場面ではもっともらしく出る。
@MainActor
struct SunGlareTests {
    /// 東京あたり。
    private let origin = CLLocationCoordinate2D(latitude: 35.0, longitude: 139.0)

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    private func date(_ hour: Int, _ minute: Int = 0) -> Date {
        // 春分。太陽がほぼ真東から昇るので、方位を取り違えたときのずれが読みやすい。
        calendar.date(from: DateComponents(year: 2026, month: 3, day: 20,
                                           hour: hour, minute: minute))!
    }

    /// 太陽が低く出ている朝の 1 点。**時刻を決め打ちしない**——季節と緯度で動くので、
    /// そのときの太陽をそのまま基準にする。
    /// **`!` で開かないこと。** 太陽の計算を壊すとこの探索は空振りするので、force unwrap だと
    /// テストの過程ごと落ちて、同じ実行にいるほかのテストまで巻き添えで失敗する。
    private func lowMorningSun() throws -> (time: Date, sun: SolarPosition) {
        let start = date(4)
        return try #require((0 ..< 300)
            .map { start.addingTimeInterval(Double($0) * 60) }
            .map { (time: $0, sun: SolarPosition.at($0, coordinate: origin)) }
            .first { $0.sun.altitude >= 8 && $0.sun.altitude <= 10 })
    }

    /// `bearing` の方角へまっすぐ伸びる経路。
    ///
    /// **緯度経度から直に組む**。`SunGlareAdvisor` の方位は `MKMapPoint` 平面で
    /// 測っているので、同じ計算で作った経路を渡すと、符号を取り違えていても
    /// 辻褄が合ってしまう。
    private func route(bearing: Double, kilometres: Double, minutes: Double) -> NavRoute {
        route(legs: [(bearing, kilometres * 1_000)], minutes: minutes)
    }

    /// （方角, 長さ）を継ぎ足した経路。
    ///
    /// **緯度経度から直に組む**。`SunGlareAdvisor` の方位は `MKMapPoint` 平面で
    /// 測っているので、同じ計算で作った経路を渡すと、符号を取り違えていても
    /// 辻褄が合ってしまう。
    private func route(legs: [(bearing: Double, metres: Double)], minutes: Double) -> NavRoute {
        let metresPerDegree = SyntheticRoute.metersPerDegreeLatitude
        var current = origin
        var coordinates = [current]

        for leg in legs {
            let radians = leg.bearing * .pi / 180
            for _ in 0 ..< Int(leg.metres / 100) {
                current = CLLocationCoordinate2D(
                    latitude: current.latitude + cos(radians) * 100 / metresPerDegree,
                    longitude: current.longitude + sin(radians) * 100
                        / (metresPerDegree * cos(origin.latitude * .pi / 180)))
                coordinates.append(current)
            }
        }
        return SyntheticRoute.shaped(coordinates, expectedTravelTime: minutes * 60)
    }

    @Test("太陽へ向かって走るときに出る")
    func facingTheSun() throws {
        let morning = try lowMorningSun()
        let glare = SunGlareAdvisor.find(on: route(bearing: morning.sun.azimuth, kilometres: 20, minutes: 20),
                                         departure: morning.time)

        #expect(glare?.sun == .morning)
        #expect((glare?.duration ?? 0) >= 120)
    }

    @Test("背中に太陽があるときは出ない")
    func sunBehind() throws {
        let morning = try lowMorningSun()
        let glare = SunGlareAdvisor.find(on: route(bearing: morning.sun.azimuth + 180, kilometres: 20, minutes: 20),
                                         departure: morning.time)
        #expect(glare == nil)
    }

    /// 高さの条件を外すと、これが落ちる。真南を向いて走れば正午の太陽は正面にあるが、
    /// そのときの眩しさはバイザーの仕事。
    @Test("太陽が高い時間には出ない")
    func middayIsTooHigh() {
        let noon = date(12)
        let sun = SolarPosition.at(noon, coordinate: origin)
        #expect(SunGlareAdvisor.find(on: route(bearing: sun.azimuth, kilometres: 20, minutes: 20),
                                     departure: noon) == nil)
    }

    @Test("日が沈んでいれば出ない")
    func nightIsQuiet() {
        let night = date(1)
        #expect(SunGlareAdvisor.find(on: route(bearing: 90, kilometres: 20, minutes: 20),
                                     departure: night) == nil)
    }

    /// 長さの下限を外すと、下の 2 分の経路でも出るようになる。
    /// **かたまりの下限（`minimumPiece`）では止まらない長さ**にしてある——そちらで
    /// 落ちてしまうと、この条件を消しても誰も気づかない。
    @Test("短い区間なら出ない")
    func briefGlareIsIgnored() throws {
        let morning = try lowMorningSun()
        let long = SunGlareAdvisor.find(on: route(bearing: morning.sun.azimuth, kilometres: 20, minutes: 20),
                                        departure: morning.time)
        let brief = SunGlareAdvisor.find(on: route(bearing: morning.sun.azimuth, kilometres: 3, minutes: 2),
                                         departure: morning.time)

        #expect(long != nil)
        #expect(brief == nil)
    }

    /// **方位の符号を裏返したときに落ちるのはこれだけ。** 東西を軸に折り返すと
    /// この 2 本が入れ替わるので、両方を見ないと気づけない
    /// （`MKMapPoint` の y は南へ向かって増える）。
    @Test("東西で折り返しても同じにならない")
    func bearingIsNotMirrored() throws {
        let morning = try lowMorningSun()
        let facing = morning.sun.azimuth + 15
        let mirrored = 180 - facing

        #expect(SunGlareAdvisor.find(on: route(bearing: facing, kilometres: 20, minutes: 20),
                                     departure: morning.time) != nil)
        #expect(SunGlareAdvisor.find(on: route(bearing: mirrored, kilometres: 20, minutes: 20),
                                     departure: morning.time) == nil)
    }

    /// **かたまりを捨ててから束ねる**、という順番を守る。逆にすると、カーブの途中で
    /// 一瞬だけ正面に来る点が数珠つなぎになって、ほぼ全行程が「西日」になる
    /// （2026-08-23 に実経路で実測。詳しくは `SunGlareAdvisor.minimumPiece`）。
    @Test("一瞬が続いても、ひと続きにはしない")
    func briefPiecesAreNotChained() throws {
        let morning = try lowMorningSun()
        // 正面 1.2km →大きく外れて 2.4km、を繰り返す。正面のかたまりはどれも 1 分未満。
        let legs = (0 ..< 8).flatMap { _ in
            [(bearing: morning.sun.azimuth, metres: 1_200.0),
             (bearing: morning.sun.azimuth + 70, metres: 2_400.0)]
        }
        #expect(SunGlareAdvisor.find(on: route(legs: legs, minutes: 24), departure: morning.time) == nil)
    }

    /// 逆に、しっかり正面を向いている区間どうしは、あいだが空いても 1 つに束ねる。
    /// 束ねないと「5 分」と言うことになるが、運転者は 11 分ぶん太陽と付き合う。
    @Test("短い途切れは挟んで数える")
    func shortGapIsBridged() throws {
        let morning = try lowMorningSun()
        let legs = [(bearing: morning.sun.azimuth, metres: 6_000.0),
                    (bearing: morning.sun.azimuth + 70, metres: 1_200.0),
                    (bearing: morning.sun.azimuth, metres: 6_000.0)]
        let glare = SunGlareAdvisor.find(on: route(legs: legs, minutes: 11), departure: morning.time)

        #expect((glare?.duration ?? 0) >= 8 * 60)
    }

    @Test("経路の方位はそのまま読める")
    func bearingReadsAsCompass() {
        let north = SunGlareAdvisor.bearing(from: origin, to: SyntheticRoute.coordinate(north: 1_000))
        let east = SunGlareAdvisor.bearing(from: origin, to: SyntheticRoute.coordinate(north: 0, east: 1_000))

        #expect(abs(north) < 1 || abs(north - 360) < 1)
        #expect(abs(east - 90) < 1)
    }

    @Test("夕方の太陽は西日として出る")
    func eveningIsNamed() throws {
        let start = date(15)
        let evening = try #require((0 ..< 240)
            .map { start.addingTimeInterval(Double($0) * 60) }
            .map { (time: $0, sun: SolarPosition.at($0, coordinate: origin)) }
            .first { $0.sun.altitude <= 10 && $0.sun.altitude >= 8 })

        let glare = SunGlareAdvisor.find(on: route(bearing: evening.sun.azimuth, kilometres: 20, minutes: 20),
                                         departure: evening.time)
        #expect(glare?.sun == .evening)
    }
}
