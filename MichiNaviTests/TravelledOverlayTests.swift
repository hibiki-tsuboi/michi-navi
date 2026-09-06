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
    @Test("通過済みは青より細い灰色で描き、下に青を残さない",
          arguments: [CarPlayMapViewController.Style.full, .compact, .cluster])
    func travelledIsGreyOnTheMap(style: CarPlayMapViewController.Style) throws {
        let controller = CarPlayMapViewController(style: style)
        let map = try #require(controller.view as? MKMapView)
        let route = SyntheticRoute.straight([("", 0), ("直進", 1000)])

        controller.show(route: route)
        controller.showTravelled(progress(remaining: 400), of: route)

        let travelled = try #require(
            map.overlays(in: .aboveRoads).last { $0 !== route.polyline } as? MKPolyline)
        // **地図に聞くこと。** `controller.mapView(map, rendererFor:)` を直に呼ぶと、
        // 代入が済んだあとの状態で聞き直すことになり、順序の誤りが素通りする。
        let renderer = try #require(map.renderer(for: travelled) as? MKPolylineRenderer)
        let remaining = try #require(map.renderer(for: route.polyline) as? MKPolylineRenderer)

        #expect(renderer.strokeColor != .systemBlue)
        #expect(renderer.lineWidth > 0)
        #expect(renderer.lineWidth < remaining.lineWidth)
        #expect(renderer.strokeEnd > 0 && renderer.strokeEnd < 1)
        #expect(remaining.strokeStart == renderer.strokeEnd)

        // 折り返しで同じ道を通る場合は、これから通る青を優先する。
        let overlays = map.overlays(in: .aboveRoads)
        let greyIndex = try #require(overlays.firstIndex { $0 === travelled })
        let blueIndex = try #require(overlays.firstIndex { $0 === route.polyline })
        #expect(greyIndex < blueIndex)
    }

    @Test("進捗更新では同じ線の境目が進み、到着時は青を最後まで消す")
    func progressUpdatesExistingRenderers() throws {
        let controller = CarPlayMapViewController()
        let map = try #require(controller.view as? MKMapView)
        let route = SyntheticRoute.straight([("", 0), ("直進", 1000)])
        controller.show(route: route)
        let travelled = try #require(map.overlays.first { $0 is TravelledPolyline })
        let grey = try #require(map.renderer(for: travelled) as? MKPolylineRenderer)
        let blue = try #require(map.renderer(for: route.polyline) as? MKPolylineRenderer)
        #expect(grey.strokeEnd == 0)
        #expect(blue.strokeStart == 0)

        controller.showTravelled(progress(remaining: 600), of: route)
        let first = blue.strokeStart
        controller.showTravelled(progress(remaining: 20), of: route)
        #expect(blue.strokeStart > first)
        #expect(grey.strokeEnd == blue.strokeStart)

        // 直前の更新から 50m 未満でも、到着したら終端まで塗り分ける。
        controller.showTravelled(progress(remaining: 0), of: route)
        #expect(blue.strokeStart == 1)
        #expect(grey.strokeEnd == 1)
        #expect(map.overlays.contains { $0 === travelled })
    }

    @Test("描画用の線が案内用の座標より細かくても、正しい区間で塗り分ける",
          arguments: [1.0, 0.5])
    func usesDisplayGeometry(remainingSegmentFraction: Double) throws {
        let origin = SyntheticRoute.origin
        let corner = SyntheticRoute.coordinate(north: 400)
        let destination = SyntheticRoute.coordinate(north: 400, east: 600)
        let shape = MKPolyline(coordinates: [origin, corner, destination], count: 3)
        let coarse = SyntheticRoute.shaped([origin, destination])
        // MKRoute.polyline と step の座標列は同じとは限らない。
        let route = NavRoute(name: coarse.name, distance: coarse.distance,
                             expectedTravelTime: coarse.expectedTravelTime, polyline: shape,
                             steps: coarse.steps, advisoryNotices: [], destination: coarse.destination,
                             waypoints: [], waypointStepIndices: [],
                             coordinates: coarse.coordinates, stepEndIndices: coarse.stepEndIndices)
        let controller = CarPlayMapViewController()
        let map = try #require(controller.view as? MKMapView)
        controller.show(route: route)

        let segmentLength = MKMapPoint(corner).distance(to: MKMapPoint(destination))
        controller.showTravelled(progress(remaining: segmentLength * remainingSegmentFraction), of: route)

        let cornerLocation = shape.location(atPointIndex: 1)
        let expected = 1 - (1 - cornerLocation) * remainingSegmentFraction
        let blue = try #require(map.renderer(for: shape) as? MKPolylineRenderer)
        #expect(abs(blue.strokeStart - expected) < 0.000001)
    }

    @Test("経路が変わったら前の塗り分けを捨て、古い進捗を反映しない")
    func replacingRouteClearsTravelledSection() throws {
        let controller = CarPlayMapViewController()
        let map = try #require(controller.view as? MKMapView)
        let oldRoute = SyntheticRoute.straight([("", 0), ("直進", 1000)])
        controller.show(route: oldRoute)
        controller.showTravelled(progress(remaining: 200), of: oldRoute)
        let oldGrey = try #require(map.overlays.first { $0 is TravelledPolyline })

        let newRoute = SyntheticRoute.straight([("", 0), ("直進", 2000)])
        controller.show(route: newRoute)
        controller.showTravelled(progress(remaining: 0), of: oldRoute)
        let newGrey = try #require(map.overlays.first { $0 is TravelledPolyline })
        let grey = try #require(map.renderer(for: newGrey) as? MKPolylineRenderer)
        let blue = try #require(map.renderer(for: newRoute.polyline) as? MKPolylineRenderer)
        #expect(!map.overlays.contains { $0 === oldGrey || $0 === oldRoute.polyline })
        #expect(grey.strokeEnd == 0)
        #expect(blue.strokeStart == 0)

        controller.show(route: nil)
        #expect(map.overlays.isEmpty)
    }
}
