import CoreLocation
import Foundation
import MapKit

/// 候補ルートのうち、これまでの走行記録と重ならない距離の割合を測る。
///
/// `TrackStore` の点は 50m 以上動いたときだけ残るため、点どうしの完全一致では測れない。
/// 履歴と候補を短い間隔で標本化し、近さに加えて線の向きも合うところを「走行済み」とする。
/// 向きを見ないと、交差しただけの道路まで走行済みになってしまう。
enum RouteNovelty {
    /// 候補表示の割合と、走行中に使う未走行区間。**同じ標本から作る**ことで、
    /// 出発前に見た数字と走り始めてからの判定が食い違わない。
    struct Analysis {
        let percentage: Int
        let profile: Profile
    }

    /// 案内開始時点で初めてだった区間。距離は経路先頭からの累積メートル。
    struct Profile: Equatable {
        struct Stretch: Equatable {
            let startDistance: CLLocationDistance
            let endDistance: CLLocationDistance
            /// リルート後も同じ区間を二度知らせないための照合位置。
            let startCoordinate: CLLocationCoordinate2D

            var distance: CLLocationDistance { endDistance - startDistance }

            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.startDistance == rhs.startDistance
                    && lhs.endDistance == rhs.endDistance
                    && lhs.startCoordinate.latitude == rhs.startCoordinate.latitude
                    && lhs.startCoordinate.longitude == rhs.startCoordinate.longitude
            }
        }

        enum Progress: Equatable {
            /// 次の初めての区間までの距離。
            case approaching(distance: CLLocationDistance)
            /// この経路で、ここまでに走った初めての道の合計。
            case exploring(distance: CLLocationDistance)
        }

        let totalDistance: CLLocationDistance
        let stretches: [Stretch]

        /// 残距離から、いま見せる探索状態を作る。初めての区間をすべて通り過ぎたら nil。
        func progress(remaining: CLLocationDistance) -> Progress? {
            let travelled = travelledDistance(remaining: remaining)

            if stretches.contains(where: {
                $0.startDistance <= travelled && travelled < $0.endDistance
            }) {
                return .exploring(distance: newDistanceTravelled(remaining: remaining))
            }
            guard let next = stretches.first(where: { $0.startDistance > travelled }) else { return nil }
            return .approaching(distance: next.startDistance - travelled)
        }

        /// 指定距離以内にある次の初めての区間。区間内なら距離 0 として返す。
        /// 経路の先頭が初めての道でも、実際に経路へ合流してから 1 回だけ知らせるため。
        func approaching(remaining: CLLocationDistance,
                         within maximumDistance: CLLocationDistance) -> (stretch: Stretch, distance: CLLocationDistance)? {
            let travelled = travelledDistance(remaining: remaining)
            guard let next = stretches.first(where: { $0.endDistance > travelled }) else { return nil }
            let distance = max(next.startDistance - travelled, 0)
            guard distance <= maximumDistance else { return nil }
            return (next, distance)
        }

        func newDistanceTravelled(remaining: CLLocationDistance) -> CLLocationDistance {
            let travelled = travelledDistance(remaining: remaining)
            return stretches.reduce(0) { result, stretch in
                result + max(min(travelled, stretch.endDistance) - stretch.startDistance, 0)
            }
        }

        private func travelledDistance(remaining: CLLocationDistance) -> CLLocationDistance {
            min(max(totalDistance - remaining, 0), totalDistance)
        }
    }

    /// 通知済みの区間をひと走りのあいだ覚える。リルートで経路の距離基準が変わっても、
    /// 開始地点が近ければ同じ道として二度知らせない。
    struct AnnouncementGate {
        private var announcedStarts: [CLLocationCoordinate2D] = []

        mutating func shouldAnnounce(_ stretch: Profile.Stretch, hasJoinedRoute: Bool) -> Bool {
            guard hasJoinedRoute else { return false }
            let start = CLLocation(latitude: stretch.startCoordinate.latitude,
                                   longitude: stretch.startCoordinate.longitude)
            guard !announcedStarts.contains(where: {
                start.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) <= 150
            }) else { return false }

            announcedStarts.append(stretch.startCoordinate)
            return true
        }
    }

    /// GPS の誤差と、実際の車線から MapKit の道路中心線までのずれを吸収する幅。
    /// 広げすぎると隣の道路を走行済みにするので、`TrackStore.accuracyLimit` より狭くする。
    static let matchingDistance: CLLocationDistance = 35
    /// 急なカーブの標本どうしは多少向きがずれる一方、交差道路（およそ 90 度）は落としたい。
    static let maximumAxisDifference = Double.pi / 4
    /// 履歴と候補を測る間隔。照合幅より細かくし、同じ線の標本が必ず近くに来るようにする。
    private static let sampleSpacing: CLLocationDistance = 25
    /// これより短い未走行区間は知らせない。GPS の取りこぼしを「新しい道」と言わないため。
    private static let minimumStretchDistance: CLLocationDistance = 200
    /// 未走行区間の間にある短い既知道路は橋渡しする。交差点だけ走行済みだった場合に、
    /// 同じ道への通知が続けて出るのを防ぐ。
    private static let maximumKnownGap: CLLocationDistance = 100

    /// 複数候補を 1 つの履歴索引でまとめて測る。
    /// ルートごとに全走行履歴を索引し直さないための入口。
    static func percentages(for routes: [NavRoute], tracks: [TrackStore.Track]) -> [Int] {
        analyses(for: routes, tracks: tracks).map(\.percentage)
    }

    /// 割合と走行中の区間を、共通の履歴索引でまとめて測る。
    static func analyses(for routes: [NavRoute], tracks: [TrackStore.Track]) -> [Analysis] {
        guard let firstCoordinate = routes.first?.coordinates.first else {
            return routes.map { _ in Analysis(percentage: 0,
                                               profile: Profile(totalDistance: 0, stretches: [])) }
        }

        var bounds = MKMapRect.null
        for route in routes where !route.coordinates.isEmpty {
            bounds = bounds.union(route.polyline.boundingMapRect)
        }

        // ルートの枠のすぐ外にある履歴も照合対象にする。候補はいずれも同じ出発地・目的地を
        // 結ぶため、先頭地点の緯度を地図点とメートルの換算基準にして差し支えない。
        let metersPerPoint = MKMetersPerMapPointAtLatitude(firstCoordinate.latitude)
        let padding = matchingDistance / max(metersPerPoint, .leastNonzeroMagnitude)
        bounds = bounds.insetBy(dx: -padding, dy: -padding)

        let history = HistoryIndex(tracks: tracks,
                                   near: bounds,
                                   referenceLatitude: firstCoordinate.latitude)
        return routes.map { analysis(for: $0, history: history) }
    }

    static func percentage(for route: NavRoute, tracks: [TrackStore.Track]) -> Int {
        analyses(for: [route], tracks: tracks).first?.percentage ?? 0
    }

    /// iPhone のブリーフと CarPlay の候補説明で同じ文言を使う。
    static func label(for percentage: Int) -> String {
        return String.localizedStringWithFormat(String(localized: "初めての道 %lld%%"),
                                                Int64(percentage))
    }

    private struct Piece {
        let startDistance: CLLocationDistance
        let endDistance: CLLocationDistance
        let startCoordinate: CLLocationCoordinate2D
        let isNew: Bool
    }

    private struct Run {
        var startDistance: CLLocationDistance
        var endDistance: CLLocationDistance
        let startCoordinate: CLLocationCoordinate2D
        var isNew: Bool
    }

    private static func analysis(for route: NavRoute, history: HistoryIndex) -> Analysis {
        let points = route.coordinates.map(MKMapPoint.init)
        guard points.count >= 2 else {
            return Analysis(percentage: 0, profile: Profile(totalDistance: 0, stretches: []))
        }

        var total: CLLocationDistance = 0
        var newDistance: CLLocationDistance = 0
        var sampled: [Piece] = []

        for (start, end) in zip(points, points.dropFirst()) {
            let length = start.distance(to: end)
            guard length > 0 else { continue }

            let pieces = max(Int(ceil(length / sampleSpacing)), 1)
            let pieceLength = length / Double(pieces)
            let axis = atan2(end.y - start.y, end.x - start.x)

            for index in 0 ..< pieces {
                let startFraction = Double(index) / Double(pieces)
                let sampleFraction = (Double(index) + 0.5) / Double(pieces)
                let pieceStart = interpolate(from: start, to: end, fraction: startFraction)
                let sample = interpolate(from: start, to: end, fraction: sampleFraction)
                let isNew = !history.contains(sample, on: axis)
                sampled.append(Piece(startDistance: total + Double(index) * pieceLength,
                                     endDistance: total + Double(index + 1) * pieceLength,
                                     startCoordinate: pieceStart.coordinate,
                                     isNew: isNew))
                if isNew {
                    newDistance += pieceLength
                }
            }
            total += length
        }

        guard total > 0 else {
            return Analysis(percentage: 0, profile: Profile(totalDistance: 0, stretches: []))
        }
        let percentage = min(max(Int((newDistance / total * 100).rounded()), 0), 100)
        return Analysis(percentage: percentage,
                        profile: Profile(totalDistance: total,
                                         stretches: meaningfulStretches(in: sampled)))
    }

    /// 標本の細かな揺れを、運転中に知らせるまとまりへ直す。
    private static func meaningfulStretches(in pieces: [Piece]) -> [Profile.Stretch] {
        var runs: [Run] = []
        for piece in pieces {
            if let last = runs.indices.last, runs[last].isNew == piece.isNew {
                runs[last].endDistance = piece.endDistance
            } else {
                runs.append(Run(startDistance: piece.startDistance,
                                endDistance: piece.endDistance,
                                startCoordinate: piece.startCoordinate,
                                isNew: piece.isNew))
            }
        }

        if runs.count >= 3 {
            for index in 1 ..< runs.count - 1
            where !runs[index].isNew
                && runs[index].endDistance - runs[index].startDistance <= maximumKnownGap
                && runs[index - 1].isNew
                && runs[index + 1].isNew {
                runs[index].isNew = true
            }
        }

        // 橋渡しで同じ種類になった隣同士をもう一度まとめる。
        var merged: [Run] = []
        for run in runs {
            if let last = merged.indices.last, merged[last].isNew == run.isNew {
                merged[last].endDistance = run.endDistance
            } else {
                merged.append(run)
            }
        }

        return merged.compactMap { run in
            guard run.isNew,
                  run.endDistance - run.startDistance >= minimumStretchDistance else { return nil }
            return Profile.Stretch(startDistance: run.startDistance,
                                   endDistance: run.endDistance,
                                   startCoordinate: run.startCoordinate)
        }
    }

    private static func interpolate(from start: MKMapPoint,
                                    to end: MKMapPoint,
                                    fraction: Double) -> MKMapPoint {
        MKMapPoint(x: start.x + (end.x - start.x) * fraction,
                   y: start.y + (end.y - start.y) * fraction)
    }

    /// 方向を反対に走っても同じ道路なので、角度は 180 度周期で比べる。
    private static func axisDifference(_ one: Double, _ other: Double) -> Double {
        var difference = abs(one - other).truncatingRemainder(dividingBy: .pi)
        if difference > .pi / 2 { difference = .pi - difference }
        return difference
    }

    private struct HistoryIndex {
        struct Cell: Hashable {
            let x: Int
            let y: Int
        }

        struct Sample {
            let point: MKMapPoint
            let axis: Double
        }

        let cellSize: Double
        let buckets: [Cell: [Sample]]

        init(tracks: [TrackStore.Track], near bounds: MKMapRect, referenceLatitude: CLLocationDegrees) {
            let metersPerPoint = MKMetersPerMapPointAtLatitude(referenceLatitude)
            cellSize = matchingDistance * 2 / max(metersPerPoint, .leastNonzeroMagnitude)

            var result: [Cell: [Sample]] = [:]
            for track in tracks {
                let points = track.coordinates.map(MKMapPoint.init)
                for (start, end) in zip(points, points.dropFirst()) {
                    let segmentBounds = MKMapRect(
                        x: min(start.x, end.x),
                        y: min(start.y, end.y),
                        width: abs(end.x - start.x),
                        height: abs(end.y - start.y)
                    ).insetBy(dx: -1, dy: -1)
                    guard bounds.intersects(segmentBounds) else { continue }

                    let length = start.distance(to: end)
                    guard length > 0 else { continue }
                    let pieces = max(Int(ceil(length / sampleSpacing)), 1)
                    let axis = atan2(end.y - start.y, end.x - start.x)

                    for index in 0 ..< pieces {
                        let fraction = (Double(index) + 0.5) / Double(pieces)
                        let point = RouteNovelty.interpolate(from: start, to: end, fraction: fraction)
                        guard bounds.contains(point) else { continue }
                        let cell = Self.cell(for: point, size: cellSize)
                        result[cell, default: []].append(Sample(point: point, axis: axis))
                    }
                }
            }
            buckets = result
        }

        func contains(_ point: MKMapPoint, on axis: Double) -> Bool {
            let center = Self.cell(for: point, size: cellSize)
            // メルカトル図法では 1 地図点の長さが緯度で変わる。高緯度の長い検索半径でも
            // 隣接セルを取りこぼさないよう、その地点で必要なセル数を求める。
            let metersPerPoint = MKMetersPerMapPointAtLatitude(point.coordinate.latitude)
            let radiusInPoints = matchingDistance / max(metersPerPoint, .leastNonzeroMagnitude)
            let radius = max(Int(ceil(radiusInPoints / cellSize)), 1)

            for x in (center.x - radius) ... (center.x + radius) {
                for y in (center.y - radius) ... (center.y + radius) {
                    for sample in buckets[Cell(x: x, y: y)] ?? [] {
                        guard point.distance(to: sample.point) <= matchingDistance else { continue }
                        if RouteNovelty.axisDifference(axis, sample.axis) <= maximumAxisDifference {
                            return true
                        }
                    }
                }
            }
            return false
        }

        private static func cell(for point: MKMapPoint, size: Double) -> Cell {
            Cell(x: Int(floor(point.x / size)), y: Int(floor(point.y / size)))
        }
    }
}
