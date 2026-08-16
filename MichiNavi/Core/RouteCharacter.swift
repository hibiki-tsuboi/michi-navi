import CoreLocation
import Foundation
import MapKit

/// 候補ルートに付ける短い特徴。
///
/// MapKit が返す候補は「12分・8.2km」と「14分・7.1km」のように、数字だけでは
/// **何が違うのか読み取れない**。運転中に選ばせるなら、違いを一言にしないと選べない。
///
/// 出す語は必ず**候補どうしの比較**から決める。「右折が少ない」は他より少ないから
/// 意味があるのであって、単独のルートに付けても情報にならない。候補が 1 本しか
/// 無いときは何も出さない。
enum RouteCharacter {
    /// 候補ごとの特徴。並びは `routes` と同じ。
    static func tags(for routes: [NavRoute]) -> [[String]] {
        guard routes.count > 1 else { return routes.map { _ in [] } }

        // `map(Profile.init(route:))` と書かないこと。関数として渡すと MainActor の
        // 隔離が落ちる（既定で全部が MainActor なので、初期化子も MainActor 隔離）。
        let profiles = routes.map { Profile(route: $0) }
        var tags = [[String]](repeating: [], count: routes.count)

        // 同じ値で並んだときに全員へ付けない。いちばん良いものが 1 本のときだけ出す。
        func markBest<T: Comparable>(_ values: [T], by isBetter: (T, T) -> Bool, label: String) {
            guard let best = values.min(by: isBetter) else { return }
            let winners = values.indices.filter { !isBetter(best, values[$0]) && !isBetter(values[$0], best) }
            guard winners.count == 1, let index = winners.first else { return }
            tags[index].append(label)
        }

        markBest(routes.map(\.expectedTravelTime), by: <, label: String(localized: "最短時間"))
        markBest(routes.map(\.distance), by: <, label: String(localized: "距離が短い"))
        markBest(profiles.map(\.rightTurns), by: <, label: String(localized: "右折が少ない"))

        // 高速の有無は比較ではなく事実として出す。ただし全部が同じなら違いにならない。
        let usesHighway = profiles.map(\.usesHighway)
        if Set(usesHighway).count > 1 {
            for index in routes.indices {
                tags[index].append(usesHighway[index] ? String(localized: "高速を使う") : String(localized: "下道のみ"))
            }
        }

        // カーブは「多いほう」だけ出す。少ないのは既定なのでわざわざ言わない。
        let curvature = profiles.map(\.curvature)
        if let most = curvature.max(), let least = curvature.min(),
           most > least * Self.curvatureRatio,
           let index = curvature.firstIndex(of: most) {
            tags[index].append(String(localized: "カーブが多い"))
        }

        return tags
    }

    /// 「カーブが多い」と言い出す差。1.5 倍は、山越えと平野の差では出て、
    /// 同じような道どうしでは出ない程度。
    private static let curvatureRatio: Double = 1.5

    /// 曲がりくねった順に並べ替える。
    ///
    /// **できるのは候補の並べ替えまで**。MapKit に「曲がりくねった道を引いて」と
    /// 頼む手段は無く、返ってきた 2〜3 本から選び直すだけなので、平野では何も変わらない。
    /// それでも山沿いでは目に見えて違う候補が返るので、選ぶ手間だけ省く価値はある。
    static func sortedByCurvature(_ routes: [NavRoute]) -> [NavRoute] {
        let scored = routes.map { (route: $0, curvature: Profile(route: $0).curvature) }
        return scored.sorted { $0.curvature > $1.curvature }.map(\.route)
    }

    private struct Profile {
        let rightTurns: Int
        let usesHighway: Bool
        /// 1km あたりの方位変化（ラジアン）。道の曲がりくねり具合。
        let curvature: Double

        init(route: NavRoute) {
            let directions = route.steps.map { ManeuverDirection.inferred(from: $0.instruction) }
            rightTurns = directions.count(where: \.isRightTurn)
            usesHighway = directions.contains(where: \.entersHighway)
            curvature = Self.curvature(of: route)
        }

        /// 連続する区間どうしの方位差を積み上げ、距離で割る。
        ///
        /// 距離で割るのは、長いルートほど曲がりの総量が増えるのが当たり前だから。
        /// 割らずに比べると、遠回りのルートが必ず「カーブが多い」になる。
        private static func curvature(of route: NavRoute) -> Double {
            let points = route.coordinates.map(MKMapPoint.init)
            guard points.count >= 3 else { return 0 }

            var total: Double = 0
            var previousAngle: Double?
            for index in 1 ..< points.count {
                let dx = points[index].x - points[index - 1].x
                let dy = points[index].y - points[index - 1].y
                guard dx != 0 || dy != 0 else { continue }

                let angle = atan2(dy, dx)
                if let previousAngle {
                    // -π…π をまたぐ差を素直な角度に畳む。畳まないと直進が
                    // 「2π 曲がった」と数えられる。
                    var delta = angle - previousAngle
                    while delta > .pi { delta -= 2 * .pi }
                    while delta < -.pi { delta += 2 * .pi }
                    total += abs(delta)
                }
                previousAngle = angle
            }

            let kilometres = max(route.distance / 1_000, 0.1)
            return total / kilometres
        }
    }
}
