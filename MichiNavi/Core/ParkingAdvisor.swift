import Combine
import CoreLocation
import MapKit

/// 目的地の手前で、停められる場所をひとつ提案する。
///
/// カーナビは目的地の座標へ着いた時点で仕事を終えるが、**車で行く以上そこで
/// 終わりではない**。着いてから停める場所を探すことになると、探しはじめる時点で
/// もう目的地の前にいるので、周りを回りながら探すしかない。まだ手前にいて
/// 進路を選べるうちに 1 件出す。
///
/// ほかの助言の層（`RestReminder` / `RangeAdvisor` / `RouteWeather`）と同じく、
/// **こちらから案内を変えることはしない**。押されたときだけ行き先が変わる。
@MainActor
final class ParkingAdvisor {
    static let shared = ParkingAdvisor()

    struct Advice {
        let place: Place
        /// 目的地からの距離。**停めたあと歩く距離**なので、寄るかどうかの判断はこれで決まる。
        let walkingDistance: CLLocationDistance
    }

    /// 提案が決まった瞬間に流れる。
    let advice = PassthroughSubject<Advice, Never>()

    private let navigation = NavigationController.shared
    private let destinations = DestinationStore.shared

    /// 残りがこれを切ったら探し始める。
    ///
    /// 早すぎると出したところで「まだ先の話」になり、遅すぎると曲がる先を決めたあとになる。
    /// 市街地の速度でおよそ 1〜2 分手前。
    private static let suggestionDistance: CLLocationDistance = 1_000

    /// 目的地からこの範囲だけ探す。
    ///
    /// **停めたあとは歩く**ので、遠い駐車場を出しても選びようがない。広げると
    /// 「空いているが 1km 歩く」が上位に来て、いちばん近い 1 件を出す意味が消える。
    private static let searchRadius: CLLocationDistance = 500

    /// いま案内している 1 回ぶん。目的地ごとに 1 度しか出さない。
    private struct Trip {
        let destinationID: String
        /// しきい値より遠い状態を一度でも見たか。
        ///
        /// 「近所への案内では出さない」をこれで判定する。**経路の全長で見ない**のは、
        /// 引き直しで返る経路が残りぶんだけの長さになるため。目的地の近くで外れると
        /// 短い案内と見分けが付かず、いちばん出したい場面で黙ることになる。
        var hasBeenFar = false
        var hasAdvised = false
    }

    private var trip: Trip?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func start() {
        navigation.$phase
            .sink { [weak self] in self?.apply(phase: $0) }
            .store(in: &cancellables)

        navigation.$progress
            .compactMap { $0 }
            .sink { [weak self] in self?.check($0) }
            .store(in: &cancellables)
    }

    /// 案内が終わったら忘れる。同じ場所へもう一度案内を始めたら、また出す。
    private func apply(phase: NavigationController.Phase) {
        if case .navigating = phase { return }
        trip = nil
    }

    private func check(_ progress: RouteProgress) {
        guard let route = navigation.currentRoute else { return }
        // 着いてしまってから出さない。GPS が 1km 以上飛ぶと、しきい値を跨いだ最初の更新が
        // そのまま到着の更新になりうる。そのときに出しても、案内はこの直後に畳まれる。
        guard !progress.hasArrived else { return }

        // **目的地で数える。** 引き直すと `NavRoute.id` は変わるが目的地は同じで、
        // そこで数え直すと外れるたびに提案が出る。
        if trip?.destinationID != route.destination.id {
            trip = Trip(destinationID: route.destination.id)
        }
        guard let current = trip, !current.hasAdvised else { return }

        guard progress.distanceRemaining <= Self.suggestionDistance else {
            trip?.hasBeenFar = true
            return
        }
        // 遠い状態を一度も見ていない＝始めた時点でもう目の前だった、ということ。
        guard current.hasBeenFar else { return }

        // 探すより先に立てる。検索は数秒かかり、そのあいだにも位置更新は来る。
        trip?.hasAdvised = true
        Task { await suggest(near: route.destination) }
    }

    private func suggest(near destination: Place) async {
        // **自宅と職場では出さない。** いつも停めている場所があるので、提案は邪魔にしかならない。
        // この 2 つが「数が増えず、いちばん押される行き先」だという `Pinned` の前提がそのまま効く。
        guard destination != destinations.home, destination != destinations.work else { return }
        // 目的地が駐車場そのものなら、停める場所はもう決まっている。
        // 履歴から戻した `Place` はカテゴリを持たない（座標から組み直しているため）ので、
        // ここをすり抜けることがある。下の重複除外がその受け皿。
        guard destination.mapItem.pointOfInterestCategory != .parking else { return }

        guard let places = try? await SearchService.shared.nearby(pointsOfInterest: [.parking],
                                                                  around: destination.coordinate,
                                                                  radius: Self.searchRadius) else { return }

        // `nearby` は渡した座標に近い順に返すので、先頭が目的地にいちばん近い。
        // **補給先（`RangeAdvisor`）が「届く範囲でいちばん先」を選ぶのと逆になる。**
        // あちらは走り続けるための寄り道、こちらは降りて歩いて戻る場所だから。
        guard let place = places.first(where: {
            $0 != destination && ParkingName.isForCars($0.name)
        }) else { return }

        let walking = CLLocation(latitude: destination.coordinate.latitude,
                                 longitude: destination.coordinate.longitude)
            .distance(from: CLLocation(latitude: place.coordinate.latitude,
                                       longitude: place.coordinate.longitude))
        // 範囲は `nearby` にも渡してあるが、`MKLocalPointsOfInterestRequest` の半径は
        // 目安でしかなく、外の結果が混ざることがある。歩けない距離なら黙る。
        guard walking <= Self.searchRadius else { return }

        advice.send(Advice(place: place, walkingDistance: walking))
    }
}

/// `.parking` で返ってくる地点から、**車を停められないもの**を名前で落とす。
///
/// `MKPointOfInterestCategory` に駐輪場・ロータリー・乗降場の区分は無く、どれも
/// `.parking` として返ってくる（iOS 26 のカテゴリ一覧を見てもそれらしいものは無い）。
/// 数のうえでは全体の 5% でしかないが、**駅前ではそれが最寄りに来る**。駐輪場も
/// ロータリーも駅の真ん前にあるので、「いちばん近い 1 件を出す」という作りと
/// 最悪の相性になる。2026-08-16 に 14 地点・430 件で実測したところ、6 地点
/// （東京・みなとみらい・大阪・名古屋・京都・那覇）で停められない場所が 1 位だった。
///
/// **落としすぎる側に倒してある。** 本物の駐車場を 1 件落としても次に近いものへ
/// 移るだけで、実測では最大 30m 遠くなっただけ（東京駅 161m → 192m）。逆に駐輪場を
/// 出すと、案内はそこまで引き直されたうえで着いた先に停められない。
///
/// **表は訳さない。** 端末の言語で返る名前が変わるので、日英を同じ配列に並べて
/// 両方を見る（`ManeuverDirection` / `VoiceCommand` と同じ）。英語は小文字で書くこと。
enum ParkingName {
    /// 車を停める場所ではない印。
    ///
    /// **「バス」を単独で入れないこと。** 「三井のリパーク 那覇バスターミナル前 駐車場」の
    /// ような本物の駐車場が落ちる。落としたいのは「新宿南側バス駐車場」のほうなので複合語にする。
    private static let notForCars = [
        "駐輪", "自転車", "サイクル", "バイク", "二輪", "ロータリー", "乗降", "バス駐車",
        "bicycle", "bike", "cycle", "motorcycle", "moped", "scooter",
        "roundabout", "drop-off", "drop off",
    ]

    /// 判定の前に取り除く語。**これを飛ばすと「リサイクル」が「サイクル」で落ちる。**
    /// 打ち消しが先で判定が後、という順序に意味のある表（`ManeuverDirection` が
    /// 長い語を短い語より先に置いているのと同じ性質）。
    private static let notSuspicious = ["リサイクル", "recycle"]

    static func isForCars(_ name: String) -> Bool {
        var cleaned = name.lowercased()
        for word in notSuspicious {
            cleaned = cleaned.replacingOccurrences(of: word, with: "")
        }
        return !notForCars.contains { cleaned.contains($0) }
    }
}
