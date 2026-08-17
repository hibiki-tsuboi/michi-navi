import CoreLocation
import MapKit
@testable import MichiNavi

/// テスト用の合成経路。
///
/// **実物の `MKRoute` は作れない**（MapKit が返すものしか無い）ので、`NavRoute` の
/// メンバーワイズ初期化で組み立てる。案内の計算に効くのは `coordinates` と
/// `stepEndIndices` と各 step の距離だけなので、そこさえ本物と同じ形になっていればよい。
///
/// **北へまっすぐ伸びる線**にしてある。経度方向は緯度によって 1 度あたりの距離が変わるが、
/// 緯度方向なら地球上どこでも同じなので、メートルと座標の対応が読んで分かる。
enum SyntheticRoute {
    /// MapKit が使う球の半径から出した、緯度 1 度あたりのメートル。
    /// `MKMapPoint` の距離計算もこの球に乗っているので、換算の誤差は無視できる
    /// （`RouteMeasurementTests` で実際に確かめている）。
    static let metersPerDegreeLatitude = 111_319.49

    static let origin = CLLocationCoordinate2D(latitude: 35.0, longitude: 139.0)

    /// 座標を 1 点ずつ間隔 `spacing` で並べた直線経路を作る。
    ///
    /// - Parameter steps: 各区間の（指示文, 長さ）。**先頭に 0m の区間を置くこと**が
    ///   多い。MapKit の実データがそうなっているため（`steps[0]` は 0m で指示文も空）。
    static func straight(_ steps: [(instruction: String, length: CLLocationDistance)],
                         spacing: CLLocationDistance = 10,
                         expectedTravelTime: TimeInterval = 600) -> NavRoute {
        var coordinates: [CLLocationCoordinate2D] = [origin]
        var stepEndIndices: [Int] = []
        var navSteps: [NavStep] = []
        /// 出発地から並べ終えたところまでの距離。
        var travelled: CLLocationDistance = 0

        for step in steps {
            let start = coordinates.count - 1
            let end = travelled + step.length
            // 長さ 0 の区間ではここを 1 度も通らない。**それでよい**——MapKit の
            // `steps[0]` は 0m なので、同じ形（終端が直前と同じ添字）を再現する。
            while travelled + 0.001 < end {
                travelled = min(travelled + spacing, end)
                coordinates.append(coordinate(north: travelled))
            }
            stepEndIndices.append(coordinates.count - 1)
            navSteps.append(NavStep(instruction: step.instruction,
                                    notice: nil,
                                    distance: step.length,
                                    coordinates: Array(coordinates[start...])))
        }

        return NavRoute(name: "テスト経路",
                        distance: steps.reduce(0) { $0 + $1.length },
                        expectedTravelTime: expectedTravelTime,
                        polyline: MKPolyline(coordinates: coordinates, count: coordinates.count),
                        steps: navSteps,
                        advisoryNotices: [],
                        destination: place("目的地", at: coordinates[coordinates.count - 1]),
                        waypoints: [],
                        waypointStepIndices: [],
                        coordinates: coordinates,
                        stepEndIndices: stepEndIndices)
    }

    /// 好きな形の 1 区間だけを持つ経路。**カーブの多さを比べる**ときに使う。
    /// 距離は `MKMapPoint` 上で測る（`RouteCharacter` と同じ数え方）。
    static func shaped(_ coordinates: [CLLocationCoordinate2D],
                       instruction: String = "直進",
                       expectedTravelTime: TimeInterval = 600) -> NavRoute {
        let points = coordinates.map(MKMapPoint.init)
        let distance = zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }

        return NavRoute(name: "テスト経路",
                        distance: distance,
                        expectedTravelTime: expectedTravelTime,
                        polyline: MKPolyline(coordinates: coordinates, count: coordinates.count),
                        steps: [NavStep(instruction: instruction,
                                        notice: nil,
                                        distance: distance,
                                        coordinates: coordinates)],
                        advisoryNotices: [],
                        destination: place("目的地", at: coordinates[coordinates.count - 1]),
                        waypoints: [],
                        waypointStepIndices: [],
                        coordinates: coordinates,
                        stepEndIndices: [coordinates.count - 1])
    }

    /// 出発地から北へ `meters` 進んだ座標。
    static func coordinate(north meters: CLLocationDistance,
                           east: CLLocationDistance = 0) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: origin.latitude + meters / metersPerDegreeLatitude,
            longitude: origin.longitude + east / (metersPerDegreeLatitude * cos(origin.latitude * .pi / 180)))
    }

    /// 測位 1 回ぶん。**精度と速度を必ず指定する**——逸脱判定も引き直しの可否も
    /// この 2 つを見ているので、既定任せにするとテストが何を確かめているか読めなくなる。
    static func fix(at coordinate: CLLocationCoordinate2D,
                    accuracy: CLLocationAccuracy = 5,
                    speed: CLLocationSpeed = 10) -> CLLocation {
        CLLocation(coordinate: coordinate,
                   altitude: 0,
                   horizontalAccuracy: accuracy,
                   verticalAccuracy: 5,
                   course: 0,
                   speed: speed,
                   timestamp: Date())
    }

    static func place(_ name: String, at coordinate: CLLocationCoordinate2D) -> Place {
        Place(mapItem: MKMapItem(location: CLLocation(latitude: coordinate.latitude,
                                                      longitude: coordinate.longitude),
                                 address: nil),
              fallbackName: name)
    }
}
