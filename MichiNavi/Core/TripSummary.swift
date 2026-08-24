import Combine
import Foundation

/// ひと走りの終わりに、**その走行で初めて通った土地**を数える。
///
/// 「マイルのように貯まるもの」の中身をどう選ぶか、という判断がこの層の全部。
/// 貯めるのは**距離ではなく「初めて」**にしてある。理由は 3 つあって、どれも
/// 距離を数えたときに実際に困ることのほう。
///
/// - **距離を報酬にすると `RestReminder` と逆を向く。** 一方で「そろそろ休憩しませんか」と
///   言いながら、走るほど得だとも言うことになる。
/// - **記録はアプリを開いているあいだしか残らない**（`TrackStore` の背景測位は案内中だけ）。
///   通算距離は必ず実際より少なくなるので、**取りこぼしが「損」として効く**数え方とは
///   相性が悪い。「初めて」なら取りこぼしても次に同じ道を通れば拾えるので、欠落が害にならない。
/// - **毎日の通勤で増えない。** 増えるのは知らない道へ入ったときだけなので、
///   **知らない道を選ぶ理由**になる。距離だとただ長く走った日が勝つ。
///
/// **測るだけで、出し方は決めない。** 読み上げるかどうかは `VoiceGuidance` が
/// `VisitAdvisor.isEnabled` を見て決める（`SolarPosition` ↔ `SunGlareAdvisor`、
/// `JunctionGeometry` ↔ `JunctionImage` と同じ分け方）。
///
/// 材料は `TrackStore` がもう持っているものだけで、問い合わせも許可も 1 件も増えない。
/// 裏返して、**`TrackStore.isRecording` を切ると `visits` が増えないので必ず黙る**。
@MainActor
final class TripSummary {
    static let shared = TripSummary()

    /// ひと走りの収穫。**「初めて」が 1 つも無ければ作らない**（nil ＝ 黙る）。
    ///
    /// 到着は運転者が降りるところなので、**言うことが無いなら言わない**のがここでいちばん
    /// 効く決めごと。毎日の通勤では必ず nil になり、その日は何も鳴らない。
    struct Harvest: Equatable {
        /// この走行で初めて入った都道府県の 1 つ目。無ければ nil。
        let prefecture: String?
        /// この走行で初めて走った市区町村の数。
        let cities: Int
        /// 通算。**貯まっていることが分かるのはこの数字だけ**なので、必ず添える。
        let totalPrefectures: Int
        let totalCities: Int
    }

    /// 出発時の控え。**差を取るために要る**——`Visit.first` の日付で数えると、
    /// 日付をまたぐ走行と「今日 2 度目の外出」が区別できない。
    struct Mark: Equatable {
        let prefectures: Set<String>
        let cities: Int
    }

    private var mark: Mark?
    private var cancellables = Set<AnyCancellable>()

    /// **見るのは `activeRoute` で `phase` ではない。** 走行中に次の行き先を探すと
    /// `phase` は `.previewing` へ戻るが、車はまだ元の経路の上にいる（同じひと走り）。
    func start() {
        NavigationController.shared.$activeRoute
            .sink { [weak self] in self?.apply(route: $0) }
            .store(in: &cancellables)
    }

    private func apply(route: NavRoute?) {
        // 案内が終わったら控えを捨てる。次のひと走りは、そのときの通算から数え直す。
        guard route != nil else {
            mark = nil
            return
        }
        // **控え直さない。** 引き直しでも目的地の変更でも `activeRoute` は入れ替わるが、
        // どちらも同じひと走りの続きなので、控え直すとそこまでの収穫が消える。
        guard mark == nil else { return }
        mark = Mark(prefectures: Self.prefectures(in: TrackStore.shared.visits),
                    cities: TrackStore.shared.visits.count)
    }

    /// いまのひと走りの収穫。**副作用が無い**ので、いつ呼んでも同じ値を返す。
    ///
    /// 呼ぶのは到着の 1 か所だけ（`VoiceGuidance`）。**到着（`arrived`）は
    /// `activeRoute` が nil になる前に流れる**ので、そこで呼べば控えはまだ生きている。
    func harvest() -> Harvest? {
        guard let mark else { return nil }
        return Self.harvest(since: mark, visits: TrackStore.shared.visits)
    }

    /// 控えといまの記録から収穫を作る。**純粋な計算**なので、履歴を引数で受ける
    /// （`VisitAdvisor.notice(for:...)` と同じ形。テストから直に呼ぶ）。
    static func harvest(since mark: Mark, visits: [TrackStore.Visit]) -> Harvest? {
        let cities = visits.count - mark.cities
        // **都道府県は並び順を保って拾う。** `Set` の差では「1 つ目」が実行のたびに
        // 変わる。`visits` は見つけた順に積まれているので、そのまま辿れば入った順になる。
        let prefecture = visits.first { !$0.prefecture.isEmpty && !mark.prefectures.contains($0.prefecture) }?.prefecture

        guard cities > 0 || prefecture != nil else { return nil }
        return Harvest(prefecture: prefecture,
                       cities: cities,
                       totalPrefectures: prefectures(in: visits).count,
                       totalCities: visits.count)
    }

    /// 空を数えない。市区町村しか返らない国では都道府県が空になるので、
    /// そのまま数えると「初めての都道府県」が 1 つ増えたことになる。
    static func prefectures(in visits: [TrackStore.Visit]) -> Set<String> {
        Set(visits.map(\.prefecture).filter { !$0.isEmpty })
    }
}
