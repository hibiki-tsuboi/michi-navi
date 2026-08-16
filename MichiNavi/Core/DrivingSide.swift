import Combine
import CoreLocation
import MapKit

/// 走っている国が道路のどちら側を走るか。
///
/// 効くのはロータリーの回り方。CarPlay へ `CPManeuver.trafficSide` として渡すと、
/// 車のメーター・HUD に出る記号の向きが変わる。**既定は右側通行**なので、
/// 渡さないと日本のロータリーで回転方向が逆に描かれる。
enum DrivingSide {
    case left
    case right

    /// 左側通行の国・地域（ISO 3166-1 alpha-2）。
    ///
    /// 走行側を教えてくれる API は無いので表で持つしかない。**変わることがある**
    /// （直近ではサモアが 2009 年に右→左、ミャンマーが 1970 年に左→右）ため、
    /// 増減の可能性を前提に、判定は「表に載っていれば左、それ以外は右」に倒してある。
    private static let leftHandRegions: Set<String> = [
        // アジア
        "BD", "BN", "BT", "HK", "ID", "IN", "JP", "LK", "MO", "MV", "MY", "NP", "PK", "SG", "TH", "TL",
        // オセアニア
        "AU", "CC", "CK", "CX", "FJ", "KI", "NF", "NR", "NU", "NZ", "PG", "PN", "SB", "TO", "TV", "WS",
        // アフリカ
        "BW", "KE", "LS", "MU", "MW", "MZ", "NA", "SC", "SH", "SZ", "TZ", "UG", "ZA", "ZM", "ZW",
        // ヨーロッパ
        "CY", "GB", "GG", "IE", "IM", "JE", "MT",
        // 南北アメリカ・カリブ
        "AG", "AI", "BB", "BM", "BS", "DM", "FK", "GD", "GY", "JM", "KN", "KY",
        "LC", "MS", "SR", "TC", "TT", "VC", "VG",
        // インド洋
        "IO",
    ]

    static func inRegion(_ region: Locale.Region?) -> DrivingSide {
        guard let region else { return .right }
        return leftHandRegions.contains(region.identifier) ? .left : .right
    }
}

/// いまいる国の通行区分を持つ。
///
/// MapKit は経路にも地点にも走行国を付けてこない（履歴から戻した `MKMapItem` は
/// 座標しか持たない）ので、**現在地を逆ジオコーディングして国を引く**。
///
/// 引き直しは滅多に要らない。国境をまたがない限り変わらないので、測位のたびに
/// 引いても MapKit のレート制限に近づくだけ。一定以上動いたときにだけ引き直す。
@MainActor
final class DrivingSideLocator: ObservableObject {
    static let shared = DrivingSideLocator()

    @Published private(set) var current: DrivingSide

    /// 最後に国を引いた地点。ここからの距離で引き直しを決める。
    private var resolvedNear: CLLocation?
    private var isResolving = false
    private var cancellables = Set<AnyCancellable>()

    /// 引き直す距離。国境をまたいだら気づける程度に短く、
    /// 逆ジオコーディングを連打しない程度には長く。
    private static let refreshDistance: CLLocationDistance = 100_000

    private init() {
        // 測位が来るまでは端末の地域で代用する。**大半はこれで合っている**
        // （自分の国で運転する）ので、最初の 1 経路が既定の右側通行になるより良い。
        current = DrivingSide.inRegion(Locale.current.region)

        LocationService.shared.$location
            .compactMap { $0 }
            .sink { [weak self] in self?.handle(location: $0) }
            .store(in: &cancellables)
    }

    private func handle(location: CLLocation) {
        guard !isResolving else { return }
        if let resolvedNear, location.distance(from: resolvedNear) < Self.refreshDistance { return }

        isResolving = true
        Task {
            defer { isResolving = false }
            guard let region = await Self.region(at: location) else { return }
            // 引けたときだけ基準を進める。失敗を覚えると、次の測位でまた引いてしまう。
            resolvedNear = location
            current = DrivingSide.inRegion(region)
        }
    }

    private static func region(at location: CLLocation) async -> Locale.Region? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        guard let items = try? await request.mapItems else { return nil }
        return items.first?.addressRepresentations?.region
    }
}
