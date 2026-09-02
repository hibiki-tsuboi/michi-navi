import CoreLocation
import Foundation
import MapKit

/// 候補ルートのうち、これまでの走行記録と重ならない距離の割合を測る。
///
/// `TrackStore` の点は 50m 以上動いたときだけ残るため、点どうしの完全一致では測れない。
/// 履歴と候補を短い間隔で標本化し、近さに加えて線の向きも合うところを「走行済み」とする。
/// 向きを見ないと、交差しただけの道路まで走行済みになってしまう。
enum RouteNovelty {
    /// GPS の誤差と、実際の車線から MapKit の道路中心線までのずれを吸収する幅。
    /// 広げすぎると隣の道路を走行済みにするので、`TrackStore.accuracyLimit` より狭くする。
    static let matchingDistance: CLLocationDistance = 35
    /// 急なカーブの標本どうしは多少向きがずれる一方、交差道路（およそ 90 度）は落としたい。
    static let maximumAxisDifference = Double.pi / 4
    /// 履歴と候補を測る間隔。照合幅より細かくし、同じ線の標本が必ず近くに来るようにする。
    private static let sampleSpacing: CLLocationDistance = 25

    /// 複数候補を 1 つの履歴索引でまとめて測る。
    /// ルートごとに全走行履歴を索引し直さないための入口。
    static func percentages(for routes: [NavRoute], tracks: [TrackStore.Track]) -> [Int] {
        guard let firstCoordinate = routes.first?.coordinates.first else {
            return routes.map { _ in 0 }
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
        return routes.map { percentage(for: $0, history: history) }
    }

    static func percentage(for route: NavRoute, tracks: [TrackStore.Track]) -> Int {
        percentages(for: [route], tracks: tracks).first ?? 0
    }

    /// iPhone のブリーフと CarPlay の候補説明で同じ文言を使う。
    static func label(for percentage: Int) -> String {
        return String.localizedStringWithFormat(String(localized: "初めての道 %lld%%"),
                                                Int64(percentage))
    }

    private static func percentage(for route: NavRoute, history: HistoryIndex) -> Int {
        let points = route.coordinates.map(MKMapPoint.init)
        guard points.count >= 2 else { return 0 }

        var total: CLLocationDistance = 0
        var newDistance: CLLocationDistance = 0

        for (start, end) in zip(points, points.dropFirst()) {
            let length = start.distance(to: end)
            guard length > 0 else { continue }

            let pieces = max(Int(ceil(length / sampleSpacing)), 1)
            let pieceLength = length / Double(pieces)
            let axis = atan2(end.y - start.y, end.x - start.x)

            for index in 0 ..< pieces {
                let fraction = (Double(index) + 0.5) / Double(pieces)
                let point = interpolate(from: start, to: end, fraction: fraction)
                total += pieceLength
                if !history.contains(point, on: axis) {
                    newDistance += pieceLength
                }
            }
        }

        guard total > 0 else { return 0 }
        return min(max(Int((newDistance / total * 100).rounded()), 0), 100)
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
