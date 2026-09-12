import Combine
import Network

/// 通信できるかどうかだけを見る。
///
/// **MapKit は経路計算も検索もすべてネットワーク越し**なので、山間部・トンネル・
/// 地下駐車場で切れているあいだは必ず失敗する。失敗してから気づくのではなく、
/// 投げる前に分かるようにするための層。
///
/// **これは「通信できる」の保証ではない。** `NWPathMonitor` が見ているのは経路が
/// 張れているかどうかで、電波 1 本で実際にはタイムアウトする状態でも `.satisfied` を
/// 返す。あくまで**はっきり切れているときを拾うだけ**で、それ以外の失敗は
/// `NavigationController` の再試行の間隔に任せる。
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    /// 通信できるか。
    ///
    /// **判定が付くまでは true にしておく。** 起動直後に false から始めると、まだ何も
    /// 分かっていない時点で圏外の扱いになり、案内を始めることそのものを止めてしまう。
    /// 通信が本当に無ければ、最初の問い合わせが失敗したときに分かる。
    @Published private(set) var isOnline = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "jp.hibiki.michinavi.network")

    private init() {}

    func start() {
        monitor.pathUpdateHandler = { path in
            // `NWPath` を跨がせず、真偽値にしてから MainActor へ渡す。
            let online = path.status == .satisfied
            Task { @MainActor in NetworkMonitor.shared.isOnline = online }
        }
        monitor.start(queue: queue)
    }
}
