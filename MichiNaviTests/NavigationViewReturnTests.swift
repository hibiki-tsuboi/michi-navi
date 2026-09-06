import CoreLocation
import MapKit
import Testing
import UIKit

@testable import MichiNavi

@MainActor
struct NavigationViewReturnTests {
    private func makeMap() throws -> (CarPlayMapViewController, MKMapView) {
        let controller = CarPlayMapViewController()
        let map = try #require(controller.view as? MKMapView)
        map.frame = CGRect(x: 0, y: 0, width: 800, height: 480)
        map.layoutIfNeeded()
        controller.follow(location: CLLocation(latitude: 35.68, longitude: 139.76), animated: false)
        return (controller, map)
    }

    @Test("追従したまま縮小しても、ナビへ戻すボタンの切り替えが通知される")
    func zoomingOutOffersNavigationReturn() throws {
        let (controller, _) = try makeMap()
        var offered: [Bool] = []
        controller.onNavigationViewChanged = { offered.append(controller.needsNavigationReturn) }
        defer { controller.onNavigationViewChanged = nil }

        #expect(!controller.needsNavigationReturn)
        controller.zoomOut()
        #expect(controller.isFollowingUser)
        #expect(offered.last == true)

        // 手動で元の縮尺まで戻した場合も「全体表示」へ切り替わる。
        controller.zoomIn()
        #expect(offered.last == false)
    }

    @Test("縮小後は1回の復帰で最大拡大になり、次の測位でも縮尺を保つ")
    func oneReturnRestoresMaximumZoom() throws {
        let (controller, map) = try makeMap()
        for _ in 0..<6 { controller.zoomOut() }
        let zoomedOut = controller.cameraState().distance

        controller.recenter(zoomToMaximum: true)
        let restored = controller.cameraState().distance
        #expect(restored < zoomedOut)
        #expect(abs(map.camera.centerCoordinateDistance - restored) < 2)
        #expect(controller.isFollowingUser)
        #expect(!controller.needsNavigationReturn)

        // もう1回拡大しても変わらないことが、上限まで戻した証拠。
        controller.zoomIn()
        #expect(controller.cameraState().distance == restored)

        let next = CLLocation(latitude: 35.681, longitude: 139.76)
        controller.follow(location: next, animated: false)
        #expect(MKMapPoint(map.centerCoordinate).distance(to: MKMapPoint(next.coordinate)) < 1)
        #expect(abs(map.camera.centerCoordinateDistance - restored) < 2)
    }

    @Test("全体表示から復帰した後、カードの出入りで全体表示に引き戻されない")
    func overviewDoesNotReturnAfterNavigationResumes() throws {
        let (controller, map) = try makeMap()
        let route = SyntheticRoute.straight([("", 0), ("直進", 20_000)])
        controller.showRouteOverview(route)
        #expect(controller.needsNavigationReturn)

        controller.recenter(zoomToMaximum: true)
        let current = CLLocation(latitude: 35.69, longitude: 139.76)
        controller.follow(location: current, animated: false)
        let restored = map.camera.centerCoordinateDistance

        // 全体表示の当て込みが残っていると、ここで経路全体へ引き直される。
        controller.viewSafeAreaInsetsDidChange()
        #expect(MKMapPoint(map.centerCoordinate).distance(to: MKMapPoint(current.coordinate)) < 1)
        #expect(abs(map.camera.centerCoordinateDistance - restored) < 2)
        #expect(!controller.needsNavigationReturn)
    }

    @Test("通常の現在地への復帰は、利用者が選んだ縮尺を保つ")
    func ordinaryRecenterPreservesZoom() throws {
        let (controller, _) = try makeMap()
        controller.setFollowingUser(false)
        controller.zoomOut()
        let chosen = controller.cameraState().distance

        controller.recenter()
        #expect(controller.isFollowingUser)
        #expect(controller.cameraState().distance == chosen)
        #expect(controller.needsNavigationReturn)
    }
}
