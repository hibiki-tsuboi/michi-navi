import Foundation
import Testing
@testable import MichiNavi

/// 通行区分の表。効くのは `CPManeuver.trafficSide` で、**ロータリーの回り方**が変わる。
///
/// 走行側を教えてくれる API は無いので表で持つしかない。判定は
/// **「表に載っていれば左、それ以外は右」**に倒してあり、知らない国は右側通行として扱う。
struct DrivingSideTests {
    @Test("左側通行の国", arguments: ["JP", "GB", "AU", "NZ", "IN", "TH", "ZA", "IE", "HK"])
    func leftHandRegions(code: String) {
        #expect(DrivingSide.inRegion(Locale.Region(code)) == .left)
    }

    @Test("右側通行の国", arguments: ["US", "DE", "FR", "CN", "KR", "BR", "MM"])
    func rightHandRegions(code: String) {
        #expect(DrivingSide.inRegion(Locale.Region(code)) == .right)
    }

    @Test("国が分からなければ右（既定に倒す）")
    func unknownRegionFallsBackToRight() {
        #expect(DrivingSide.inRegion(nil) == .right)
        #expect(DrivingSide.inRegion(Locale.Region("ZZ")) == .right)
    }
}
