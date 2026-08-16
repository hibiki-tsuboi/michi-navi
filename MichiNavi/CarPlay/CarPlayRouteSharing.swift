import CarPlay
import CoreLocation
import MapKit

/// 走っている経路そのものを車へ渡すための変換層（iOS 26.4 以降、ガイド p.61）。
///
/// 目的地を渡すだけの「目的地共有」と違い、こちらは経路の形・区間ごとの指示・座標列を
/// 車に預ける。先進運転支援を積んだ車はそれを見て車線案内を出したり、走り方を経路へ
/// 寄せたりする。EV は充電状態と突き合わせて **経由地を送り返してくる**（充電に寄れ）。
///
/// `CPRouteSegment` は**経由地の切れ目で区切った 1 区間**を表す。`NavRoute` は
/// 経由地ごとの区間を 1 本に繋いでしまっているので、ここで `waypointStepIndices` を
/// 頼りに区切り直す。経由地が無ければ区間は 1 つ。
///
/// 区間に入れる `CPManeuver` は、`CarPlayCoordinator.routeManeuvers` と**同じインスタンス**を
/// 受け取ってそのまま使う。別に作ると `updateEstimates(for:)` の宛先が食い違う。
@available(iOS 26.4, *)
@MainActor
final class CarPlayRouteSharing {
    /// いま車に預けている区間と、それぞれが受け持つ step の範囲。添字は対応している。
    private var segments: [CPRouteSegment] = []
    private var stepRanges: [ClosedRange<Int>] = []
    /// いま走っている区間の添字。またいだときだけ CarPlay へ伝えるために覚えておく。
    private var currentIndex: Int?
    /// 区間がどの経路のものか。**引き直した直後に古い区間を指さないための鍵**。
    /// 経路が入れ替わると `CPManeuver` の側が先に作り直され、まだ区間が古いまま
    /// step の添字だけ新しい、という一瞬がある。
    private var routeID: UUID?

    // MARK: - セッションへの受け渡し

    /// セッション開始時に全区間を積む。
    ///
    /// `addRouteSegments` は `CPNavigationSession.add(_:)` と同じで**積み上げる** API。
    /// 引き直すたびに呼ぶとセッションに古い経路のぶんが溜まるので、ここでしか呼ばない。
    /// 入れ替えは `resume`（`resumeTrip`）の側が丸ごと担う。
    func begin(session: CPNavigationSession,
               route: NavRoute,
               maneuvers: [CPManeuver],
               stepIndex: Int,
               tripEstimates: CPTravelEstimates) {
        rebuild(route: route, maneuvers: maneuvers, stepIndex: stepIndex, tripEstimates: tripEstimates)
        guard !segments.isEmpty else { return }

        session.addRouteSegments(segments)
        currentIndex = nil
        updateCurrentSegment(session: session, routeID: route.id, stepIndex: stepIndex)
    }

    /// 引き直した経路で区間を作り直し、案内を再開する。
    /// 呼ぶ前に `pauseTrip` で止まっていること（ガイド p.61 の手順）。
    func resume(session: CPNavigationSession,
                route: NavRoute,
                maneuvers: [CPManeuver],
                stepIndex: Int,
                tripEstimates: CPTravelEstimates,
                reason: CPRerouteReason) {
        rebuild(route: route, maneuvers: maneuvers, stepIndex: stepIndex, tripEstimates: tripEstimates)
        guard let index = indexOfSegment(containing: stepIndex) else { return }

        currentIndex = index
        session.resumeTrip(updatedRouteSegments: segments,
                           currentSegment: segments[index],
                           rerouteReason: reason)
    }

    /// 区間をまたいだら車へ伝える。経由地を通過した瞬間がこれにあたる。
    ///
    /// **同じ区間のあいだは代入しない**。`currentSegment` は代入のたびに車側が
    /// 区間の切り替わりと受け取るので、区間が変わっていないのに毎回渡すと、
    /// 到着予定が区間の先頭へ巻き戻ったように見える。
    ///
    /// `routeID` を照らすのは、引き直しの最中に呼ばれるため。`CPManeuver` の作り直しが
    /// 先に走るので、**step の添字は新しい経路のものなのに区間はまだ古い**という一瞬がある。
    /// そこで古い区間を指してしまうと、直後の `resume` まで車が別の区間を掴む。
    func updateCurrentSegment(session: CPNavigationSession, routeID: UUID, stepIndex: Int) {
        guard self.routeID == routeID,
              let index = indexOfSegment(containing: stepIndex),
              index != currentIndex else { return }

        currentIndex = index
        session.currentSegment = segments[index]
    }

    func clear() {
        segments = []
        stepRanges = []
        currentIndex = nil
        routeID = nil
    }

    // MARK: - 区間の組み立て

    private func rebuild(route: NavRoute,
                         maneuvers: [CPManeuver],
                         stepIndex: Int,
                         tripEstimates: CPTravelEstimates) {
        // step と maneuver は 1 対 1 で作られているが、片方だけ短い状態で
        // 添字を作ると範囲外になる。短い方に合わせる。
        let stepCount = min(route.steps.count, maneuvers.count)
        let legs = Self.legs(of: route, stepCount: stepCount)

        var builtSegments: [CPRouteSegment] = []
        var builtRanges: [ClosedRange<Int>] = []
        // 出発地は経路の先頭。`Place` を持たないので座標だけで作る。
        var origin = Self.waypoint(at: route.coordinates.first ?? route.destination.coordinate,
                                   name: "現在地")

        for leg in legs {
            let destination = Self.waypoint(for: leg.destination)
            // 「いま向かっている指示」は案内カードと同じ切り出し方に揃える。
            // まだ入っていない区間では、その区間の先頭から数える。
            let from = min(max(stepIndex, leg.range.lowerBound), leg.range.upperBound)
            let upcoming = Array(maneuvers[from...leg.range.upperBound].prefix(2))

            let segment = Self.withCoordinates(Self.coordinates(of: route, in: leg.range)) { points, count in
                CPRouteSegment(__origin: origin,
                               destination: destination,
                               maneuvers: Array(maneuvers[leg.range]),
                               // MapKit は車線情報を返さないので空のまま。
                               // `currentLaneGuidance` は非 nil を要求されるので形だけ渡す。
                               laneGuidances: [],
                               currentManeuvers: upcoming,
                               currentLaneGuidance: CPLaneGuidance(),
                               tripTravelEstimates: tripEstimates,
                               maneuverTravelEstimates: upcoming.first?.initialTravelEstimates ?? tripEstimates,
                               coordinates: points,
                               coordinatesCount: count)
            }

            builtSegments.append(segment)
            builtRanges.append(leg.range)
            // 次の区間の出発地は、この区間の目的地。
            origin = destination
        }

        segments = builtSegments
        stepRanges = builtRanges
        routeID = route.id
    }

    /// 経由地の切れ目で step を区切り、区間ごとの行き先と組にして返す。
    ///
    /// `waypointStepIndices` は各経由地に着く step の添字。最後の step に載っている
    /// 経由地は、目的地と区別できないので区間を切らない（空の区間ができてしまう）。
    private static func legs(of route: NavRoute,
                             stepCount: Int) -> [(range: ClosedRange<Int>, destination: Place)] {
        guard stepCount > 0 else { return [] }

        var result: [(range: ClosedRange<Int>, destination: Place)] = []
        var start = 0
        for (place, end) in zip(route.waypoints, route.waypointStepIndices)
        where end >= start && end < stepCount - 1 {
            result.append((start...end, place))
            start = end + 1
        }
        result.append((start...(stepCount - 1), route.destination))
        return result
    }

    /// 区間が受け持つ範囲の座標列。`NavRoute.remainingCoordinates(from:)` と同じ数え方。
    private static func coordinates(of route: NavRoute,
                                    in range: ClosedRange<Int>) -> [CLLocationCoordinate2D] {
        guard route.stepEndIndices.indices.contains(range.upperBound) else { return [] }

        let start = range.lowerBound == 0 ? 0 : route.stepEndIndices[range.lowerBound - 1]
        let end = route.stepEndIndices[range.upperBound]
        guard start <= end, route.coordinates.indices.contains(end) else { return [] }
        return Array(route.coordinates[start...end])
    }

    /// step の添字がどの区間に入るか。
    ///
    /// どの範囲にも入らないときは端に寄せる。区間を見失って `currentSegment` を
    /// 据え置くより、ずれていても最後の区間を指しているほうが車の表示は崩れない。
    private func indexOfSegment(containing stepIndex: Int) -> Int? {
        if let index = stepRanges.firstIndex(where: { $0.contains(stepIndex) }) { return index }
        guard !stepRanges.isEmpty else { return nil }
        return stepIndex < 0 ? 0 : stepRanges.count - 1
    }

    // MARK: - CarPlay の地点表現へ

    /// 目的地・経由地を車へ渡す形にする。
    static func waypoint(for place: Place) -> CPNavigationWaypoint {
        withCoordinates([]) { points, count in
            // 進入口（建物のどの入口から入るか）は MapKit が返さないので渡さない。
            CPNavigationWaypoint(__mapItem: place.mapItem,
                                 locationThreshold: nil,
                                 entryPoints: points,
                                 entryPointsCount: count)
        }
    }

    /// 座標しか無い地点（出発地）を車へ渡す形にする。
    static func waypoint(at coordinate: CLLocationCoordinate2D, name: String) -> CPNavigationWaypoint {
        withCoordinates([]) { points, count in
            CPNavigationWaypoint(__centerPoint: CPLocationCoordinate3D(coordinate),
                                 locationThreshold: nil,
                                 name: name,
                                 address: nil,
                                 entryPoints: points,
                                 entryPointsCount: count,
                                 timeZone: nil)
        }
    }

    /// C の配列を要求する API へ座標を渡す。
    ///
    /// **空配列のポインタは渡せない**。引数が nonnull なのに、Swift の空 `Array` から
    /// 取れる `baseAddress` は nil になる。渡す座標が無いときのために 1 要素だけ確保して、
    /// 個数の方に 0 を渡す。
    private static func withCoordinates<T>(
        _ coordinates: [CLLocationCoordinate2D],
        _ body: (UnsafeMutablePointer<CPLocationCoordinate3D>, Int) -> T
    ) -> T {
        var points = coordinates.isEmpty
            ? [CPLocationCoordinate3D(kCLLocationCoordinate2DInvalid)]
            : coordinates.map(CPLocationCoordinate3D.init)
        let count = coordinates.count
        return points.withUnsafeMutableBufferPointer { body($0.baseAddress!, count) }
    }
}

@available(iOS 26.4, *)
extension CPLocationCoordinate3D {
    /// 高度は MapKit の経路に含まれない。ヘッダの指定どおり「不明」を表す値を入れる。
    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude,
                  longitude: coordinate.longitude,
                  altitude: CLLocationDistanceMax)
    }
}

// MARK: - 車から来た地点

@available(iOS 26.4, *)
extension Place {
    /// 車が送ってきた地点をアプリ側で扱える形にする。
    ///
    /// 変換をここ（CarPlay 層）に置いているのは、`Core/` に CarPlay を持ち込まないため。
    /// 確かなのは座標だけで、名前も住所も付いてこないことがある。
    init?(vehicleWaypoint waypoint: CPNavigationWaypoint) {
        let center = waypoint.centerPoint
        let coordinate = CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude)
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }

        // 住所は改行区切りの 1 本の文字列で来る（ヘッダの例のとおり）。
        // こちらの表示はどこも 1 行なので、その場で繋いでおく。
        let address = waypoint.address
            .map { $0.split(separator: "\n").joined(separator: " ") }
            .flatMap { MKAddress(fullAddress: $0, shortAddress: nil) }

        self.init(mapItem: MKMapItem(location: CLLocation(latitude: coordinate.latitude,
                                                          longitude: coordinate.longitude),
                                     address: address),
                  fallbackName: waypoint.name)
    }
}
