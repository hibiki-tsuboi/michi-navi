import CoreLocation
import MapKit

/// 走行履歴を同じ大きさのメッシュへ落とし、探索した広がりを地図にする。
///
/// 道路総延長は MapKit から取得できないので、根拠のない「地域の走破率」は出さない。
/// 代わりに、実際に通ったメッシュ数と概算面積を積み上げる。
enum ExplorationCoverage {
    /// Web Mercator の世界を 2^16 分割する。日本付近では 1 辺がおよそ 500m。
    static let divisions = 65_536
    static let cellSize = MKMapRect.world.width / Double(divisions)

    struct Cell: Identifiable, Hashable {
        let x: Int
        let y: Int

        var id: String { "\(x):\(y)" }

        var coordinates: [CLLocationCoordinate2D] {
            let minX = Double(x) * ExplorationCoverage.cellSize
            let minY = Double(y) * ExplorationCoverage.cellSize
            let maxX = minX + ExplorationCoverage.cellSize
            let maxY = minY + ExplorationCoverage.cellSize
            return [
                MKMapPoint(x: minX, y: minY).coordinate,
                MKMapPoint(x: maxX, y: minY).coordinate,
                MKMapPoint(x: maxX, y: maxY).coordinate,
                MKMapPoint(x: minX, y: maxY).coordinate
            ]
        }

        /// メルカトル図法の縮尺をセル中央の緯度で補正した概算面積。
        var squareKilometers: Double {
            let center = MKMapPoint(x: (Double(x) + 0.5) * ExplorationCoverage.cellSize,
                                    y: (Double(y) + 0.5) * ExplorationCoverage.cellSize)
            let metersPerPoint = MKMetersPerMapPointAtLatitude(center.coordinate.latitude)
            let side = ExplorationCoverage.cellSize * metersPerPoint
            return side * side / 1_000_000
        }
    }

    struct Summary {
        let cells: [Cell]
        let squareKilometers: Double

        init(tracks: [TrackStore.Track]) {
            cells = ExplorationCoverage.cells(for: tracks)
            squareKilometers = cells.reduce(0) { $0 + $1.squareKilometers }
        }
    }

    static func cells(for tracks: [TrackStore.Track]) -> [Cell] {
        var visited = Set<Cell>()

        for track in tracks {
            guard let first = track.coordinates.first else { continue }
            var previous = MKMapPoint(first)
            visited.insert(cell(containing: previous))

            for coordinate in track.coordinates.dropFirst() {
                let current = MKMapPoint(coordinate)
                // 記録点が粗くても、その間を通ったメッシュが抜けないようセル半分ごとに補間する。
                let longestDelta = max(abs(current.x - previous.x), abs(current.y - previous.y))
                let pieces = max(Int(ceil(longestDelta / (cellSize / 2))), 1)
                for index in 1...pieces {
                    let fraction = Double(index) / Double(pieces)
                    let point = MKMapPoint(x: previous.x + (current.x - previous.x) * fraction,
                                           y: previous.y + (current.y - previous.y) * fraction)
                    visited.insert(cell(containing: point))
                }
                previous = current
            }
        }

        return visited.sorted { left, right in
            left.y == right.y ? left.x < right.x : left.y < right.y
        }
    }

    static func cell(containing coordinate: CLLocationCoordinate2D) -> Cell {
        cell(containing: MKMapPoint(coordinate))
    }

    private static func cell(containing point: MKMapPoint) -> Cell {
        let x = min(max(Int(floor(point.x / cellSize)), 0), divisions - 1)
        let y = min(max(Int(floor(point.y / cellSize)), 0), divisions - 1)
        return Cell(x: x, y: y)
    }
}
