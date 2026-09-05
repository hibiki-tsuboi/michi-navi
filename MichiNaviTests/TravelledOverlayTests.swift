import CoreLocation
import MapKit
import Testing
import UIKit

@testable import MichiNavi

/// 通ってきたところの塗り替え（`CarPlayMapViewController.showTravelled`）。
///
/// **地図に載せたあとの色を見る。** `mapView(_:rendererFor:)` を直に呼ぶ書き方では、
/// この節がいちばん守りたい順序を見逃す——`MKMapView` は **`addOverlay` の内側で
/// 同期的に**レンダラを要求し、しかも結果をキャッシュするので、色の決め手を
/// 足したあとに用意すると**その線は最後まで青いまま**になる（実測。2026-09-05）。
@MainActor
struct TravelledOverlayTests {
    private func progress(remaining: CLLocationDistance) -> RouteProgress {
        RouteProgress(stepIndex: 1,
                      distanceToNextManeuver: remaining,
                      distanceRemaining: remaining,
                      timeRemaining: 60,
                      snappedCoordinate: CLLocationCoordinate2D(latitude: 35.68, longitude: 139.76),
                      distanceFromRoute: 0,
                      isOffRoute: false,
                      hasArrived: false,
                      hasJoinedRoute: true)
    }

    /// **これが落ちると、案内中に通った道と、これから通る道が同じ青で並ぶ。**
    @Test("通ってきたところは地図の上でも灰色で描かれる")
    func travelledIsGreyOnTheMap() throws {
        let controller = CarPlayMapViewController(style: .full)
        let map = try #require(controller.view as? MKMapView)
        let route = SyntheticRoute.straight([("", 0), ("直進", 1000)])

        controller.show(route: route)
        controller.showTravelled(progress(remaining: 400), of: route)

        let travelled = try #require(
            map.overlays(in: .aboveRoads).last { $0 !== route.polyline } as? MKPolyline)
        // **地図に聞くこと。** `controller.mapView(map, rendererFor:)` を直に呼ぶと、
        // 代入が済んだあとの状態で聞き直すことになり、順序の誤りが素通りする。
        let renderer = try #require(map.renderer(for: travelled) as? MKPolylineRenderer)

        #expect(renderer.strokeColor != .systemBlue)
    }
}
