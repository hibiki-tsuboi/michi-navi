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

    private let defaults: UserDefaults
    private static let tollsKey = "route.avoidsTolls"
    private static let highwaysKey = "route.avoidsHighways"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 既定はどちらも「避けない」。速い順に出すのが素直で、避けたい人だけが入れる。
        avoidsTolls = defaults.bool(forKey: Self.tollsKey)
        avoidsHighways = defaults.bool(forKey: Self.highwaysKey)
    }

    /// `MKDirections.Request` に渡す形。
    var tollPreference: MKDirections.RoutePreference { avoidsTolls ? .avoid : .any }
    var highwayPreference: MKDirections.RoutePreference { avoidsHighways ? .avoid : .any }

    /// 設定が効いていることを画面に出すための短い説明。何も避けていなければ nil。
    var summary: String? {
        switch (avoidsTolls, avoidsHighways) {
        case (true, true): "有料道路と高速を避けています"
        case (true, false): "有料道路を避けています"
        case (false, true): "高速を避けています"
        case (false, false): nil
        }
    }
}
