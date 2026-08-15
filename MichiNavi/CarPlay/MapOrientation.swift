import CoreGraphics
import Foundation

/// 地図の向き。センターディスプレイと Dashboard の両方がこれを見る。
///
/// **CarPlay の画面だけの設定**なので `Core/` には置かない。iPhone 側の地図は
/// これを見ておらず、常に進行方向が上のまま。案内ロジックではなく見た目の設定なので、
/// 「状態は NavigationController」の対象外に置いてある。
enum MapOrientation: String {
    /// 進行方向が上。地図が回るかわりに、これから走る先が広く見える。
    case heading
    /// 北が上。地図が回らないので、街の中でいまどこにいるかを掴みやすい。
    case north

    /// 地図の傾き。北が上のときは傾けない。回転しない地図を傾けると
    /// 奥ほど潰れて、方角を読み取るという北上げの利点を消してしまう。
    var pitch: CGFloat {
        switch self {
        case .heading: 45
        case .north: 0
        }
    }

    var toggled: MapOrientation {
        self == .heading ? .north : .heading
    }

    // MARK: - 保存

    private static let key = "map.orientation"

    /// 次に乗ったときも同じ向きで始まるよう覚えておく。
    static var current: MapOrientation {
        get { UserDefaults.standard.string(forKey: key).flatMap(MapOrientation.init) ?? .heading }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
