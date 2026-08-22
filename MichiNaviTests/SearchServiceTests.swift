import CoreLocation
import Foundation
import MapKit
import Testing

@testable import MichiNavi

/// 検索の失敗の扱い。
///
/// **MapKit は 0 件を空配列ではなく失敗として返す**（`MKErrorDomain` code 4
/// ＝`MKError.placemarkNotFound`）。それを空配列に読み替えないと、呼び元が持っている
/// 「見つかりませんでした」の文言が一度も出ず、代わりに
/// 「操作を完了できませんでした。（MKErrorDomainエラー4）」が画面に出る。
/// いっぽう**読み替えを広げすぎると、圏外を「見つかりませんでした」と言う**ことになる。
@MainActor
struct SearchServiceTests {
    private func place(_ name: String, latitude: CLLocationDegrees) -> Place {
        Place(mapItem: MKMapItem(location: CLLocation(latitude: latitude, longitude: 139), address: nil),
              fallbackName: name)
    }

    private var notFound: Error {
        NSError(domain: MKErrorDomain, code: Int(MKError.placemarkNotFound.rawValue))
    }

    private var offline: Error {
        URLError(.notConnectedToInternet)
    }

    // MARK: - エラーの見分け

    @Test("0 件だけを「探したが無かった」として扱う")
    func classifiesOnlyPlacemarkNotFound() {
        #expect(SearchService.isPlacemarkNotFound(notFound))
        #expect(!SearchService.isPlacemarkNotFound(offline))
        // MapKit の別のエラーも通す（レート制限などを空配列にしないため）。
        #expect(!SearchService.isPlacemarkNotFound(
            NSError(domain: MKErrorDomain, code: Int(MKError.loadingThrottled.rawValue))))
    }

    // MARK: - 検索点の束ね方

    /// **1 点でも拾えていれば返す。** ここを外すと、4 点で見つかっていても
    /// 残り 1 点が落ちただけで結果がゼロになる。
    @Test("一部の検索点が失敗しても、拾えたぶんは返す")
    func keepsWhatWasFound() throws {
        let merged = try SearchService.merge([(index: 1, places: [place("b", latitude: 36)])],
                                            failures: [notFound])
        #expect(merged.map(\.coordinate.latitude) == [36])
    }

    /// **1 件も拾えていないなら投げ直す。** 飲んでしまうと、圏外なのに
    /// 「この先には見つかりませんでした」と言うことになる。
    @Test("1 件も拾えず失敗があるなら投げ直す")
    func rethrowsWhenNothingSurvived() {
        #expect(throws: (any Error).self) {
            try SearchService.merge([(index: 0, places: [])], failures: [self.offline])
        }
    }

    /// 失敗が無ければ 0 件は 0 件。ここで投げると「探したが無かった」を伝えられない。
    @Test("失敗が無ければ 0 件のまま返す")
    func emptyWithoutFailureIsNotAnError() throws {
        #expect(try SearchService.merge([(index: 0, places: [])], failures: []).isEmpty)
    }

    /// **手前の検索点を先に。** 走行中は「これから通る順」でないと選べない。
    @Test("手前の検索点で見つかったものを先に出し、重複を落とす")
    func ordersByPointAndDeduplicates() throws {
        let near = place("同じ店", latitude: 35)
        let far = place("先の店", latitude: 37)
        let merged = try SearchService.merge([(index: 2, places: [far, near]),
                                             (index: 0, places: [near])],
                                            failures: [])
        // 名前ではなく緯度で見る。`MKMapItem(location:address:)` が名前を自分で
        // 埋めるので、`fallbackName` は当てにできない。
        #expect(merged.map(\.coordinate.latitude) == [35, 37])
    }
}
