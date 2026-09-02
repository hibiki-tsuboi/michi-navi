import CoreLocation
import Foundation
import MapKit
import Testing
@testable import MichiNavi

/// 走行履歴を塗りつぶす「走破マップ」のメッシュ集計。
@MainActor
struct ExplorationCoverageTests {
    private let baseCell = ExplorationCoverage.cell(containing: SyntheticRoute.origin)

    @Test("同じメッシュを何度通っても1マス")
    func deduplicatesAVisitedCell() {
        let coordinates = [coordinate(x: 0.2, y: 0.2), coordinate(x: 0.8, y: 0.8)]

        let cells = ExplorationCoverage.cells(for: [track(coordinates)])

        #expect(cells == [baseCell])
    }

    @Test("記録点の間にあるメッシュも走破済みにする")
    func fillsCellsBetweenRecordedPoints() {
        let coordinates = [coordinate(x: 0.25, y: 0.5), coordinate(x: 2.75, y: 0.5)]

        let cells = ExplorationCoverage.cells(for: [track(coordinates)])

        #expect(cells.map(\.x) == [baseCell.x, baseCell.x + 1, baseCell.x + 2])
        #expect(Set(cells.map(\.y)) == [baseCell.y])
    }

    @Test("走破した概算面積をメッシュから合計する")
    func sumsExploredArea() {
        let coordinates = [coordinate(x: 0.25, y: 0.5), coordinate(x: 2.75, y: 0.5)]

        let summary = ExplorationCoverage.Summary(tracks: [track(coordinates)])

        #expect(summary.cells.count == 3)
        #expect(summary.squareKilometers > 0.4)
        #expect(summary.squareKilometers < 1.5)
    }

    private func coordinate(x: Double, y: Double) -> CLLocationCoordinate2D {
        MKMapPoint(x: (Double(baseCell.x) + x) * ExplorationCoverage.cellSize,
                   y: (Double(baseCell.y) + y) * ExplorationCoverage.cellSize).coordinate
    }

    private func track(_ coordinates: [CLLocationCoordinate2D]) -> TrackStore.Track {
        TrackStore.Track(started: Date(timeIntervalSince1970: 0),
                         coordinates: coordinates,
                         distance: 0)
    }
}
