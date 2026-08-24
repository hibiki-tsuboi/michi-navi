import CoreLocation
import Foundation
import MapKit
import Testing

@testable import MichiNavi

/// 走った道を CarPlay の地図へ敷くときの、引き直しの選び方。
///
/// **走っているあいだ 50m ごとに流れてくる**ので、毎回全部を作り直すと線の数だけ
/// `MKOverlay` を差し替えることになる。伸びるのは最後の 1 本だけ、という前提がここ。
@MainActor
struct TrackOverlayTests {
    private func track(_ count: Int) -> TrackStore.Track {
        let coordinates = (0..<count).map {
            CLLocationCoordinate2D(latitude: 35.68 + Double($0) * 0.001, longitude: 139.76)
        }
        return TrackStore.Track(started: Date(), coordinates: coordinates, distance: 0)
    }

    @Test("点が増えていない線は引き直さない")
    func unchangedTracksAreLeftAlone() {
        let tracks = [track(5), track(9)]
        let drawn = [tracks[0].id: 5, tracks[1].id: 9]
        #expect(CarPlayMapViewController.trackChanges(for: tracks, drawn: drawn) == TrackChanges())
    }

    /// 走っているあいだ伸びるのはこれ。**古いほうを外さないと重なって濃くなる**
    /// （半透明なので、重ねたぶんだけ色が乗る）。
    @Test("伸びた線は引き直して、古いほうを外す")
    func grownTrackIsReplaced() {
        let tracks = [track(5), track(9)]
        let drawn = [tracks[0].id: 5, tracks[1].id: 8]
        let changes = CarPlayMapViewController.trackChanges(for: tracks, drawn: drawn)
        #expect(changes.redraw == [tracks[1].id])
        #expect(changes.remove == [tracks[1].id])
    }

    @Test("初めて見る線は引き直しだけで、外すものは無い")
    func newTrackIsOnlyDrawn() {
        let tracks = [track(5)]
        let changes = CarPlayMapViewController.trackChanges(for: tracks, drawn: [:])
        #expect(changes.redraw == [tracks[0].id])
        #expect(changes.remove.isEmpty)
    }

    /// 利用者が記録を消したとき。**地図に残っている線を外す口はここしか無い。**
    @Test("消えた線は地図から外す")
    func removedTrackIsCleared() {
        let gone = UUID()
        let tracks = [track(5)]
        let changes = CarPlayMapViewController.trackChanges(for: tracks, drawn: [gone: 4])
        #expect(changes.remove == [gone])
        #expect(changes.redraw == [tracks[0].id])
    }

    /// 点が 1 つでは線にならない。`MKPolyline` は作れてしまうので、ここで落とす。
    @Test("点が 1 つしかない線は描かない")
    func singlePointTrackIsNotDrawn() {
        let tracks = [track(1)]
        #expect(CarPlayMapViewController.trackChanges(for: tracks, drawn: [:]) == TrackChanges())
    }

    /// **経路と同じ描き方になっていないこと。** `rendererFor` は型で振り分けているので、
    /// そこが外れると走った道が**案内の経路とまったく同じ青い太線**として描かれる
    /// （地図の上では「経路が増えた」ようにしか見えない）。
    @Test("走った道は経路と別の色・別の太さで描く")
    func trackIsDrawnUnlikeTheRoute() throws {
        let controller = CarPlayMapViewController(style: .full)
        let coordinates = [CLLocationCoordinate2D(latitude: 35.68, longitude: 139.76),
                           CLLocationCoordinate2D(latitude: 35.69, longitude: 139.76)]
        let map = MKMapView()

        let track = try #require(controller.mapView(
            map, rendererFor: TrackPolyline(coordinates: coordinates, count: coordinates.count)
        ) as? MKPolylineRenderer)
        let route = try #require(controller.mapView(
            map, rendererFor: MKPolyline(coordinates: coordinates, count: coordinates.count)
        ) as? MKPolylineRenderer)

        #expect(route.strokeColor == .systemBlue)
        #expect(track.strokeColor != .systemBlue)
        // 下地なので細い。経路と同じ太さにすると、案内の線を隠しにいく。
        #expect(track.lineWidth < route.lineWidth)
    }

    /// **経路の下でなければならない。** 上に乗ると、細いマゼンタの線が案内の青を
    /// 縦に割ることになる。順序が問題になるのは**経路のほうが先に地図へ載る**ため——
    /// 走った道は 50m ごとに伸びて載せ替わるので、`addOverlay` で足すと必ず経路の上に来る。
    @Test("走った道は経路の下に敷く")
    func trackIsDrawnBelowTheRoute() throws {
        let controller = CarPlayMapViewController(style: .full)
        let map = try #require(controller.view as? MKMapView)

        // 実際の順序（案内が始まってから走った道が伸びる）で載せる。
        controller.show(route: SyntheticRoute.straight([("", 0), ("直進", 500)]))
        controller.showTracks([track(5)])

        let overlays = map.overlays(in: .aboveRoads)
        let trackIndex = try #require(overlays.firstIndex { $0 is TrackPolyline })
        let routeIndex = try #require(overlays.lastIndex { !($0 is TrackPolyline) })
        #expect(trackIndex < routeIndex)
    }

    /// **外すと黙って壊れる。** `rendererFor` は型で見分けているので、`MKPolyline` の
    /// 初期化子が基底のインスタンスを返すようになったら、走った道が**経路とまったく同じ
    /// 青い太線**として描かれる（案内の線が増えたようにしか見えない）。
    @Test("走った道の線は型で見分けられる")
    func trackPolylineKeepsItsType() {
        let coordinates = [CLLocationCoordinate2D(latitude: 35.68, longitude: 139.76),
                           CLLocationCoordinate2D(latitude: 35.69, longitude: 139.76)]
        let line = TrackPolyline(coordinates: coordinates, count: coordinates.count)
        #expect(line as MKPolyline is TrackPolyline)
    }
}
