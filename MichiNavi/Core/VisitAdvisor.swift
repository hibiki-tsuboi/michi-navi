import Combine
import Foundation

/// **都道府県をまたいだこと**と、**初めて走る市区町村**を声で知らせる。
///
/// ほかの助言の層と同じく案内は変えない。変わるのは走り方ではなく、**走っていること
/// 自体の受け取り方**——県境を越えた、この街は初めてだ、というのはドライブでいちばん
/// 気分の変わる瞬間なのに、どのカーナビも黙っている。
///
/// 3 つの決めごとに乗っている。
///
/// - **材料は `TrackStore` がもう引いている**（3km ごとの逆ジオコーディング）ので、
///   問い合わせも許可も 1 件も増やさない。`SunGlareAdvisor` が経路の形と時計だけで
///   動くのと同じで、**書いた日から動く**（`RouteWeather` のようにケイパビリティを待たない）。
/// - **答えは自分の走行履歴なので、嘘にならない。** 観光解説を作文する道は採っていない。
///   `RoadName` が「取りこぼす側に倒す」のと、交わる道を拡大図に描かないのと同じ判断で、
///   **運転中に確かめようのないことを喋らない**。
/// - **購読するのは `TrackStore` で、`NavigationController` ではない。** いちばん言いたいのは
///   案内していない道（あちらが `LocationService` を直に購読しているのと同じ理由）。
///   通勤路や近所の買い物で県境をまたぐ人がいる。
///
/// 裏返して、**`TrackStore.isRecording` を切ると鳴らない**。土台の逆ジオコーディングごと
/// 止まるため。`TrackSheet` の説明文にそう書いてある。
@MainActor
final class VisitAdvisor: ObservableObject {
    static let shared = VisitAdvisor()

    /// 言うことが決まった 1 件。**1 回につきひと言**で、県境と初めての街が重なっても
    /// 2 つ流さない（続けて鳴らすと、2 つ目は 1 つ目の余韻に埋まる）。
    enum Notice: Equatable {
        /// 都道府県をまたいだ。`firstCity` が入っていれば、その市区町村も初めて。
        case prefecture(name: String, firstCity: String?)
        /// 都道府県は同じまま、初めての市区町村に入った。
        case firstCity(name: String)
    }

    /// 決まった瞬間に流れる。読むのは `VoiceGuidance`。
    ///
    /// **画面には出していない。** 運転席から読むものではないし（`TrackStore` を CarPlay に
    /// 出していないのと同じ）、iPhone の画面は運転中に見ない。**声だけの機能**なので、
    /// 通話中や Siri 中（`promptStyle` が `none`）には何も起きない。
    let notice = PassthroughSubject<Notice, Never>()

    /// 知らせるかどうか。**切れるようにしてある**——同乗者がいるときは楽しいが、
    /// 一人のときは黙っていてほしい種類のもの。既定は入り（`TrackStore.isRecording` と
    /// 同じで、切りで始めると誰も存在に気づかない）。
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }

    /// 初めての市区町村を続けて言わない間隔。
    ///
    /// **県境は数十キロに 1 回しか起きないが、市区町村は都心で数キロごとに変わる。**
    /// 初めて東京を横断すると千代田区・港区・渋谷区・世田谷区と続くので、抑えないと
    /// 15km のあいだに 4 回鳴る。`TrafficAdvisor` が迂回の提案に間隔を要求しているのと
    /// 同じ話で、**続けて出る助言は読み飛ばされる**。
    static let minimumInterval: TimeInterval = 300

    private let defaults: UserDefaults
    private static let enabledKey = "visit.announce"

    /// 最後に引いた都道府県。**またいだかどうかは、続けて引いた 2 件を比べないと分からない。**
    private var previousPrefecture: String?
    private var lastNoticed: Date?
    private var cancellables = Set<AnyCancellable>()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 未設定なら入り。`bool(forKey:)` は無いときも false を返すので、存在を見てから読む。
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func start() {
        TrackStore.shared.located
            .sink { [weak self] in self?.apply($0) }
            .store(in: &cancellables)
    }

    private func apply(_ located: TrackStore.Located) {
        VisitLog.located(prefecture: located.prefecture, city: located.city, isFirst: located.isFirst)

        let now = Date()
        let notice = Self.notice(for: located,
                                 previousPrefecture: previousPrefecture,
                                 lastNoticed: lastNoticed,
                                 now: now)

        // **基準は、言ったかどうかに関わらず進める。** 進めないと、切っているあいだに
        // またいだ県境が次に入れたときへ持ち越され、県の真ん中で「入りました」と言う。
        // **空のときだけ進めない**——市区町村しか返らない国では都道府県が空になるので、
        // それを基準に据えると次の 1 件が必ず「またいだ」になる。
        if !located.prefecture.isEmpty { previousPrefecture = located.prefecture }

        guard isEnabled else {
            VisitLog.skipped("disabled")
            return
        }
        guard let notice else {
            // 初めての街なのに何も出ないなら、抑えたのは間隔のほうしかない。
            VisitLog.skipped(located.isFirst ? "too-soon" : "same-ground")
            return
        }

        lastNoticed = now
        VisitLog.noticed(notice)
        self.notice.send(notice)
    }

    /// 何を言うかを決める。**純粋な計算**なので、履歴も時計も引数で受ける（テストから直に呼ぶ）。
    static func notice(for located: TrackStore.Located,
                       previousPrefecture: String?,
                       lastNoticed: Date?,
                       now: Date) -> Notice? {
        // **起動直後は県境を言わない。** 前に引いた土地を知らないので、言えるのは
        // 「いまここにいる」までで、「またいだ」ではない。`GuidanceEngine` が経路に
        // 乗るまで逸脱を数えないのと同じで、基準が無いうちは判定そのものが成り立たない。
        let crossed = previousPrefecture != nil
            && !located.prefecture.isEmpty
            && located.prefecture != previousPrefecture

        if crossed {
            // **県境は間隔で抑えない。** 続けて起きることがまず無いので催促にならず、
            // 抑えると三県境のように短い区間で 2 度またいだときに、いちばん言いたい
            // 1 件が落ちる。
            return .prefecture(name: located.prefecture, firstCity: located.isFirst ? located.city : nil)
        }

        guard located.isFirst else { return nil }
        if let lastNoticed, now.timeIntervalSince(lastNoticed) < minimumInterval { return nil }
        return .firstCity(name: located.city)
    }
}
