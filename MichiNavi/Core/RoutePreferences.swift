import Combine
import Foundation
import MapKit

/// ルートの引き方の好み。iPhone と CarPlay で同じものを見る。
///
/// **見た目の設定ではなく経路計算の入力**なので `Core/` に置く。`MapOrientation` を
/// CarPlay 側に置いているのと分かれるのはここ。あちらは同じ経路の見せ方が変わるだけだが、
/// こちらは返ってくる経路そのものが変わる。
///
/// 変えても走っている案内は引き直さない。次に計算するときから効く。走行中に
/// 経路が丸ごと入れ替わると、音声もカードも追随できずに混乱するため。
@MainActor
final class RoutePreferences: ObservableObject {
    static let shared = RoutePreferences()

    @Published var avoidsTolls: Bool {
        didSet { defaults.set(avoidsTolls, forKey: Self.tollsKey) }
    }

    @Published var avoidsHighways: Bool {
        didSet { defaults.set(avoidsHighways, forKey: Self.highwaysKey) }
    }

    /// 曲がりくねった道を優先する。
    ///
    /// **できるのは候補の並べ替えまで**（`RouteCharacter.sortedByCurvature`）。
    /// MapKit に「曲がりくねった道を引いて」と頼む手段は無い。
    @Published var prefersWinding: Bool {
        didSet { defaults.set(prefersWinding, forKey: Self.windingKey) }
    }

    private let defaults: UserDefaults
    private static let tollsKey = "route.avoidsTolls"
    private static let highwaysKey = "route.avoidsHighways"
    private static let windingKey = "route.prefersWinding"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 既定はどちらも「避けない」。速い順に出すのが素直で、避けたい人だけが入れる。
        avoidsTolls = defaults.bool(forKey: Self.tollsKey)
        avoidsHighways = defaults.bool(forKey: Self.highwaysKey)
        prefersWinding = defaults.bool(forKey: Self.windingKey)
    }

    /// `MKDirections.Request` に渡す形。
    var tollPreference: MKDirections.RoutePreference { avoidsTolls ? .avoid : .any }
    var highwayPreference: MKDirections.RoutePreference { avoidsHighways ? .avoid : .any }

    /// 設定が効いていることを画面に出すための短い説明。何も避けていなければ nil。
    var summary: String? {
        var parts: [String] = []
        if avoidsTolls { parts.append("有料道路を避ける") }
        if avoidsHighways { parts.append("高速を避ける") }
        if prefersWinding { parts.append("曲がりくねった道を優先") }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }
}
