import Combine
import CoreLocation
import MapKit

/// 経路の先で**正面から低い太陽が入る**区間を、出発時に 1 度だけ知らせる。
///
/// ほかの助言の層と同じく、案内は変えない。変わるのは運転者の支度
/// （サングラス・バイザー）と、その区間での速度。
///
/// **材料は経路の形と時計だけ**なので、問い合わせも許可も要らない。天気
/// （`RouteWeather`）が WeatherKit のケイパビリティ待ちで黙っているのと違って、
/// これは書いた日から動く。ただし**曇っているかどうかは分からない**ので、
/// 言えるのは「そういう位置関係になる」まで。
///
/// **いま見えているものは言わない**、という `RouteWeather` の線引きはここでは採らない。
/// 目の前の眩しさは窓を見れば分かるが、**それがいつまで続くか**は分からないため、
/// 出発した時点でもう日が入っている場合も出す。
@MainActor
final class SunGlareAdvisor {
    static let shared = SunGlareAdvisor()

    struct Glare: Equatable {
        enum Sun {
            case morning
            case evening
        }

        let sun: Sun
        /// その区間に入る見込みの時刻。
        let start: Date
        /// 日が入る区間の長さ。**途切れを挟むことがある**（`gapTolerance`）。
        /// カーブや高架で一瞬外れても、運転者にとっては同じひと続きだから。
        let duration: TimeInterval

        var message: String {
            let time = Formatters.arrivalText(start)
            switch sun {
            case .morning: return String(localized: "\(time) ごろから正面に朝日が入ります")
            case .evening: return String(localized: "\(time) ごろから正面に西日が入ります")
            }
        }

        /// 続く長さ。**サングラスを出すかどうかはここで決まる**ので、時刻と対で出す。
        /// 「およそ」と言っているのは按分の誤差のぶんだけでなく、途切れを含むため。
        var detail: String {
            String(localized: "およそ \(Formatters.durationText(duration)) 続きます")
        }

        /// CarPlay の候補一覧に入る短縮形。詳しい時刻と長さはブリーフ本体で見せる。
        var briefMessage: String {
            let time = Formatters.arrivalText(start)
            switch sun {
            case .morning: return String(localized: "\(time) ごろから朝日")
            case .evening: return String(localized: "\(time) ごろから西日")
            }
        }

        var symbolName: String { "sun.horizon.fill" }
    }

    /// 見つかった瞬間に流れる。案内 1 回につき最大 1 度。
    let glare = PassthroughSubject<Glare, Never>()

    private let navigation = NavigationController.shared

    /// 太陽がこれより高ければ言わない（度）。バイザーで隠せる高さ。
    private static let maximumAltitude: Double = 15
    /// 地平線より下は言わない（度）。沈んだあとの薄明かりは眩しくない。
    private static let minimumAltitude: Double = 0
    /// 進行方位と太陽の方位がこれ以内なら「正面」（度）。
    ///
    /// フロントガラスに入る範囲はもっと広いが、それは「視界に太陽がある」であって
    /// 「見たい先に太陽が重なる」ではない。**取りこぼす側に倒す**——毎回出る助言は
    /// 読み飛ばされる。
    private static let maximumOffset: Double = 20
    /// 続く時間がこれに満たない区間は言わない。
    ///
    /// **距離ではなく時間で切る。** 距離にすると、同じ 1km でも高速では 30 秒、
    /// 市街地では 2 分になり、高速でカーブ 1 つぶんの一瞬を拾ってしまう。
    private static let minimumDuration: TimeInterval = 120
    /// かたまり 1 つがこれに満たなければ、束ねる前に捨てる。
    ///
    /// **捨ててから束ねること。** 2026-08-23 の実測（下記と同じ 4 経路）で、先に束ねると
    /// カーブの途中で一瞬だけ正面に来る 1 点ものが数珠つなぎになり、**東京駅→高尾山口が
    /// 「17:30 から 38 分」＝ほぼ全行程**になった。実際に正面なのは 11 分ぶんで、
    /// 頭の 17:30 は 1 点だけの通りすがり。北へ向かう大宮の経路まで出るようになる。
    private static let minimumPiece: TimeInterval = 60
    /// 途切れてもこれ以内なら、ひと続きとして数える。
    ///
    /// **実際の道はまっすぐ太陽へ向かわない。** 2026-08-23 に東京駅→高尾山口（17:30 発）で
    /// 測ったところ、正面に入る区間は 6 分・3 分・3 分の 3 つに割れ、あいだは 4 分と 1 分だった。
    /// 割れたまま先頭だけを出すと「6 分」になるが、運転者にとっては 17 分ずっと
    /// 太陽と付き合う区間なので、それでは支度の役に立たない。
    ///
    /// **標本の間隔より広く取る必要もある。** 渋滞で 10km/h まで落ちると 500m に 3 分かかるので、
    /// 狭くすると途切れていないものまで割れる。
    private static let gapTolerance: TimeInterval = 300
    /// 経路に置く標本の間隔（メートル）。
    private static let sampleInterval: CLLocationDistance = 500
    /// 標本の数の上限。長距離でも計算量が伸びないよう、間隔のほうを広げる。
    private static let maximumSamples = 200

    private var announcementGate = AnnouncementGate()
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func start() {
        navigation.$phase
            .sink { [weak self] in self?.apply(phase: $0) }
            .store(in: &cancellables)
    }

    private func apply(phase: NavigationController.Phase) {
        guard let route = announcementGate.routeToCheck(for: phase) else { return }

        // **待つものが何も無い**ので、ほかの層と違って `Task` に逃がさない。
        // 標本 200 点ぶんの三角関数は 1 ミリ秒に満たない。
        guard let found = Self.find(on: route, departure: Date()) else { return }
        glare.send(found)
    }

    /// 日差しを探すべき経路だけを通す。太陽の計算と、画面を見たかどうかの状態を分ける。
    struct AnnouncementGate {
        /// すでに知らせた目的地。
        ///
        /// **`NavRoute.id` で数えない**（`ParkingAdvisor` と同じ理由）。あちらは引き直すたびに
        /// 変わる UUID なので、経路を外れるたびに同じことを言うことになる。
        private var advisedDestinationID: String?
        /// 案内開始前のブリーフですでに日差しを見せた目的地。
        private var briefedDestinationIDs = Set<String>()

        mutating func routeToCheck(for phase: NavigationController.Phase) -> NavRoute? {
            switch phase {
            case .idle:
                // 案内が終わったら忘れる。同じ場所へもう一度案内を始めたら、また出す。
                advisedDestinationID = nil
                briefedDestinationIDs.removeAll()
                return nil

            case .calculating:
                // ここで消すと、提示から案内開始へ進む途中の印まで失う。
                return nil

            case let .previewing(routes):
                briefedDestinationIDs = Set(routes.compactMap { route in
                    route.driveBrief?.glare == nil ? nil : route.destination.id
                })
                return nil

            case let .navigating(route):
                guard advisedDestinationID != route.destination.id else { return nil }
                advisedDestinationID = route.destination.id

                // 出発前に見た内容を、案内開始ボタンを押した直後の通知でもう一度出さない。
                guard briefedDestinationIDs.remove(route.destination.id) == nil else { return nil }
                return route
            }
        }
    }

    /// 経路の上を歩いて、正面に低い太陽が来る最初のひと続きを探す。
    ///
    /// **いちばん早く出会う 1 件だけ**を返す（`RouteWeather` と同じ）。この先ずっと
    /// 眩しいのか 2 度目があるのかを並べても、運転の支度は変わらない。
    static func find(on route: NavRoute, departure: Date) -> Glare? {
        guard route.distance > 0, route.expectedTravelTime > 0 else { return nil }

        // 1. 途切れずに正面へ来ている標本のかたまりを作る。
        var pieces: [Stretch] = []
        var previousIndex: Int?

        for (index, sample) in samples(of: route).enumerated() {
            // 到着時刻と同じ距離按分。MapKit は step ごとの所要を返さないので、
            // 経路全体の平均速度で置くしかない（`GuidanceEngine` と同じ割り切り）。
            let time = departure.addingTimeInterval(route.expectedTravelTime * sample.distance / route.distance)
            let sun = SolarPosition.at(time, coordinate: sample.coordinate)

            guard sun.altitude >= minimumAltitude,
                  sun.altitude <= maximumAltitude,
                  SolarPosition.angle(between: sun.azimuth, and: sample.bearing) <= maximumOffset else { continue }

            if var last = pieces.last, previousIndex == index - 1 {
                last.end = time
                pieces[pieces.count - 1] = last
            } else {
                pieces.append(Stretch(head: sample, start: time, end: time))
            }
            previousIndex = index
        }

        // 2. 一瞬だけのものを捨ててから、3. 近いものを束ねる。**順番が要る**（下記）。
        var stretches: [Stretch] = []
        for piece in pieces where piece.duration >= minimumPiece {
            if var last = stretches.last, piece.start.timeIntervalSince(last.end) <= gapTolerance {
                last.end = piece.end
                stretches[stretches.count - 1] = last
            } else {
                stretches.append(piece)
            }
        }

        guard let stretch = stretches.first(where: { $0.duration >= minimumDuration }) else { return nil }

        // 朝か夕かは太陽が東西どちらにあるかで決まる。眩しさは同じでも、
        // 「西日」と言われて初めて意味が通る場面がある（帰り道の西向きの直線）。
        let sun = SolarPosition.at(stretch.start, coordinate: stretch.head.coordinate)
        return Glare(sun: sun.azimuth < 180 ? .morning : .evening,
                     start: stretch.start,
                     duration: stretch.duration)
    }

    /// 正面に太陽がある標本のひと続き。
    private struct Stretch {
        let head: Sample
        let start: Date
        var end: Date

        /// **続いた長さは標本と標本のあいだで測る**ので、実際より最大 1 間隔ぶん
        /// 短く出る。取りこぼす側の誤差なのでそのままにしてある。
        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    /// 経路上の 1 点と、そこでの進行方位。
    struct Sample {
        /// 出発地からの距離。
        let distance: CLLocationDistance
        let coordinate: CLLocationCoordinate2D
        /// 次の標本へ向かう方位（度）。北が 0 の時計回り。
        let bearing: Double
    }

    /// 等間隔に置いた標本。**先頭（出発地）も入れる**——出発した時点でもう日が
    /// 入っていることがあり、そのときこそ「いつまで続くか」を言う価値がある。
    static func samples(of route: NavRoute) -> [Sample] {
        let interval = max(sampleInterval, route.distance / Double(maximumSamples))

        var points: [(distance: CLLocationDistance, coordinate: CLLocationCoordinate2D)] = []
        var travelled: CLLocationDistance = 0
        var next: CLLocationDistance = 0
        var previous: MKMapPoint?

        for coordinate in route.coordinates {
            let point = MKMapPoint(coordinate)
            travelled += previous.map { point.distance(to: $0) } ?? 0
            previous = point
            guard travelled >= next else { continue }
            points.append((travelled, coordinate))
            next = travelled + interval
        }

        // 方位は次の標本へ向かう向きで測る。最後の 1 点には次が無いので落ちる。
        return zip(points, points.dropFirst()).map { current, following in
            Sample(distance: current.distance,
                   coordinate: current.coordinate,
                   bearing: bearing(from: current.coordinate, to: following.coordinate))
        }
    }

    /// 2 点を結ぶ向き（度）。北が 0 の時計回り。
    ///
    /// **`MKMapPoint` 平面で測る**（このアプリの距離計算と同じ土俵）。メルカトルは
    /// 角度を保つので、短い区間なら方位はそのまま読める。y は**南へ向かって増える**ので、
    /// 北成分は符号を裏返して渡すこと。
    static func bearing(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) -> Double {
        let from = MKMapPoint(origin)
        let to = MKMapPoint(destination)
        let degrees = atan2(to.x - from.x, from.y - to.y) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }
}
