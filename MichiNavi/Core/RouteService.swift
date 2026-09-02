import CoreLocation
import MapKit

/// 案内 1 区間ぶんの指示。「300m 先を右折」の "右折" にあたる部分。
struct NavStep {
    let instruction: String
    let notice: String?
    let distance: CLLocationDistance
    /// この区間の形状。連結すると経路全体になる。
    let coordinates: [CLLocationCoordinate2D]
    /// 曲がる地点＝この区間の終端。
    var maneuverCoordinate: CLLocationCoordinate2D { coordinates.last ?? kCLLocationCoordinate2DInvalid }
}

/// 計算済みの 1 経路。
///
/// 経由地があっても 1 本の経路として持つ。区間ごとに引いた結果をここで繋いでしまうので、
/// `GuidanceEngine` も `VoiceGuidance` も経由地を知らないまま動く。
struct NavRoute: Identifiable {
    let id = UUID()
    let name: String
    let distance: CLLocationDistance
    let expectedTravelTime: TimeInterval
    let polyline: MKPolyline
    let steps: [NavStep]
    let advisoryNotices: [String]
    let destination: Place

    /// 立ち寄り先。並んでいる順に通ってから目的地へ向かう。
    let waypoints: [Place]
    /// 各経由地に着く step の添字。`waypoints` と同じ数だけ並ぶ。
    /// リルート時に「まだ通っていない経由地」を選び直すのに使う。
    let waypointStepIndices: [Int]

    /// 案内計算に使う経路全体の座標列（steps を連結したもの）。
    let coordinates: [CLLocationCoordinate2D]
    /// `coordinates` 上で各 step が終わる添字。
    let stepEndIndices: [Int]

    /// この経路のうち、走行履歴と重ならない距離の割合（0...100）。
    ///
    /// MapKit が経路を返したあと、`NavigationController` がその時点の `TrackStore` と照合して
    /// 入れる。経路提供側やテストが直接作った時点ではまだ測っていないので nil。
    var newRoadPercentage: Int? = nil

    /// 案内開始前に見せる、この経路の要点。走行履歴との照合が終わったあとに作る。
    var driveBrief: DriveBrief? = nil
}

extension NavRoute {
    /// 中身から作る指紋。**引き直した結果が前とまったく同じ経路かどうか**を見分ける。
    ///
    /// `id` は生成のたびに変わるので、同じ道を同じ順に曲がる経路でも別物になる。
    /// 引き直しを「`id` が変わったこと」で判定している側（`VoiceGuidance`）は、それを
    /// リルートとみなして「ルートを再検索しました」を読み上げてしまう。停まったまま
    /// 引き直すと入力が同じ＝毎回同じ経路が返るので、**同じ経路を繰り返し
    /// 「再検索しました」と読み上げる**という、いちばん不快な形になる。
    ///
    /// 座標列ではなく step の指示と距離で作る。座標は数千点あって毎回舐めると重く、
    /// 同じ道をたどるなら指示と距離も必ず一致する。
    var signature: Int {
        var hasher = Hasher()
        hasher.combine(destination.id)
        for step in steps {
            hasher.combine(step.instruction)
            hasher.combine(Int(step.distance.rounded()))
        }
        return hasher.finalize()
    }

    /// `stepIndex` から先の指示の並び。**同じ道をたどるかどうかを見分ける**ために使う。
    ///
    /// `signature` ではこれができない。あちらは距離まで見るので、**途中から引き直した
    /// 経路とは必ず食い違う**（走行中の区間だけが短くなるため）。指示だけなら、同じ道を
    /// 同じ順に曲がるかぎり一致する。
    func instructions(from stepIndex: Int) -> [String] {
        guard stepIndex < steps.count, stepIndex >= 0 else { return [] }
        return steps[stepIndex...].map(\.instruction)
    }

    /// `stepIndex` の区間の始まりから先の座標列。まだ通っていない部分を指す。
    /// ルート沿いに施設を探すときの範囲になる。
    func remainingCoordinates(from stepIndex: Int) -> [CLLocationCoordinate2D] {
        guard stepIndex > 0, stepEndIndices.indices.contains(stepIndex - 1) else { return coordinates }

        let start = stepEndIndices[stepIndex - 1]
        guard coordinates.indices.contains(start) else { return coordinates }
        return Array(coordinates[start...])
    }

    /// 通ってきたところの座標列。**残り距離から出す**（進んだ距離は持っていない）。
    ///
    /// 塗り分けは CarPlay と iPhone の両方がやるので、切り出しはここに置いて 1 つにする
    /// （見せ方——色・太さ・引き直す間隔——はそれぞれの画面が決める）。
    /// 残りが全長より長いこと（吸着の具合でありうる）は下の切り出しが受ける——
    /// 負の距離を渡すと空が返るので、こちらで 0 に丸めない。
    func travelled(remaining: CLLocationDistance) -> [CLLocationCoordinate2D] {
        NavRoute.coordinates(coordinates, upTo: distance - remaining)
    }

    /// 先頭から `distance` メートルぶんの座標列。
    /// 「ここまでなら届く」範囲を切り出して、その中だけを探すために使う。
    static func coordinates(_ coordinates: [CLLocationCoordinate2D],
                            upTo distance: CLLocationDistance) -> [CLLocationCoordinate2D] {
        guard let first = coordinates.first, distance > 0 else { return [] }

        var result = [first]
        var travelled: CLLocationDistance = 0
        var previous = MKMapPoint(first)

        for coordinate in coordinates.dropFirst() {
            let point = MKMapPoint(coordinate)
            travelled += point.distance(to: previous)
            previous = point
            guard travelled <= distance else { break }
            result.append(coordinate)
        }
        return result
    }
}

enum RouteError: LocalizedError {
    case noRouteFound

    var errorDescription: String? {
        switch self {
        case .noRouteFound: String(localized: "ルートが見つかりませんでした")
        }
    }
}

/// ルート計算の差し替え口。いまは MapKit 実装だけだが、
/// 将来 Mapbox / Valhalla などに乗り換えるときはここだけ差し替える。
protocol RouteProviding: AnyObject {
    func routes(from origin: CLLocationCoordinate2D,
                via waypoints: [Place],
                to destination: Place) async throws -> [NavRoute]

    /// **その時刻に着くつもりで走った場合の**所要時間。
    ///
    /// いまの所要時間とは別物。経路提供側は到着時刻から道路の混み具合を見積もるので、
    /// 朝の 9 時着と深夜 2 時着では返る値が違う。
    func travelTime(from origin: CLLocationCoordinate2D,
                    to destination: Place,
                    arrivingBy date: Date) async throws -> TimeInterval

    /// **いま出発した場合の**最良経路。案内中に到着予定を測り直すために使う。
    ///
    /// 返るのは経路そのものだが、**呼び出し側が勝手に差し替えてはいけない**。走行中に
    /// 経路が入れ替わると音声も案内カードも追随できないので、動かしてよいのは数字だけで、
    /// 形のほうは「いま引き直すとこうなる」という比較用（`TrafficAdvisor`）。
    ///
    /// **用途ごとに 2 回投げないこと。** 経由地があると区間の数だけ `MKDirections` を
    /// 投げるので、測り直しと迂回の判断で別々に呼ぶと問い合わせが倍になる。
    func currentBestRoute(from origin: CLLocationCoordinate2D,
                          via waypoints: [Place],
                          to destination: Place) async throws -> NavRoute
}

final class MapKitRouteProvider: RouteProviding {
    func routes(from origin: CLLocationCoordinate2D,
                via waypoints: [Place],
                to destination: Place) async throws -> [NavRoute] {
        let source = MKMapItem(location: CLLocation(latitude: origin.latitude, longitude: origin.longitude),
                               address: nil)

        // 経由地が無いときだけ候補を複数返す。選ばせる意味があるのはこの場合だけで、
        // 経由地があると区間の数だけ組み合わせが増えて選べる形にならない。
        guard !waypoints.isEmpty else {
            return try await legs(from: source, to: destination.mapItem, alternates: true)
                .map { NavRoute(legs: [$0], waypoints: [], destination: destination) }
        }

        // MKDirections は経由地を扱えないので、区間ごとに引いて繋ぐ。
        var stitched: [MKRoute] = []
        var from = source
        for place in waypoints + [destination] {
            guard let leg = try await legs(from: from, to: place.mapItem, alternates: false).first else {
                throw RouteError.noRouteFound
            }
            stitched.append(leg)
            from = place.mapItem
        }
        return [NavRoute(legs: stitched, waypoints: waypoints, destination: destination)]
    }

    func travelTime(from origin: CLLocationCoordinate2D,
                    to destination: Place,
                    arrivingBy date: Date) async throws -> TimeInterval {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: origin.latitude, longitude: origin.longitude),
                                   address: nil)
        request.destination = destination.mapItem
        request.transportType = .automobile
        request.tollPreference = RoutePreferences.shared.tollPreference
        request.highwayPreference = RoutePreferences.shared.highwayPreference
        // これを渡すと、いまの交通量ではなく**その時刻の見込み**で計算される。
        request.arrivalDate = date

        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else { throw RouteError.noRouteFound }
        // 案内に使う経路と同じく徒歩ぶんを除く。ここだけ含めると、「何時に出れば
        // よいか」が歩く時間ぶん早く出る。
        return route.drivingTravelTime
    }

    func currentBestRoute(from origin: CLLocationCoordinate2D,
                          via waypoints: [Place],
                          to destination: Place) async throws -> NavRoute {
        // `arrivalDate` を渡さないので、いまの交通量で計算される。測り直しの狙いはそこ。
        var source = MKMapItem(location: CLLocation(latitude: origin.latitude, longitude: origin.longitude),
                               address: nil)
        var stitched: [MKRoute] = []

        // 経由地があると区間の数だけ問い合わせが要る。呼ぶ間隔はそれを前提に決めること
        // （`NavigationController.travelTimeRefreshInterval`）。候補は求めない。
        // 走行中に選ばせないので要らないうえ、そのぶん問い合わせが重くなる。
        for place in waypoints + [destination] {
            guard let leg = try await legs(from: source, to: place.mapItem, alternates: false).first else {
                throw RouteError.noRouteFound
            }
            stitched.append(leg)
            source = place.mapItem
        }
        // 徒歩ぶんはここで落ちる（`NavRoute.init(legs:waypoints:destination:)`）ので、
        // 測り直しに歩く時間が混ざることはない。
        return NavRoute(legs: stitched, waypoints: waypoints, destination: destination)
    }

    private func legs(from source: MKMapItem,
                      to destination: MKMapItem,
                      alternates: Bool) async throws -> [MKRoute] {
        let request = MKDirections.Request()
        request.source = source
        request.destination = destination
        request.transportType = .automobile
        request.requestsAlternateRoutes = alternates
        // **要望であって指示ではない**。避けようがない区間（離島の有料橋など）では
        // MapKit がそのまま有料道路を含む経路を返す。返ってきた経路を弾いてはいけない。
        request.tollPreference = RoutePreferences.shared.tollPreference
        request.highwayPreference = RoutePreferences.shared.highwayPreference

        let response = try await MKDirections(request: request).calculate()
        guard !response.routes.isEmpty else { throw RouteError.noRouteFound }
        return response.routes
    }
}

private extension NavRoute {
    /// 区間を繋いで 1 本の経路にする。経由地が無ければ区間は 1 つ。
    init(legs: [MKRoute], waypoints: [Place], destination: Place) {
        var steps: [NavStep] = []
        var waypointStepIndices: [Int] = []

        for (index, leg) in legs.enumerated() {
            // **徒歩の step を落とす**（`MKRoute.drivingSteps`）。落とさないと案内が
            // 駐車地点で終わらず、「階段を上がる」を運転中に読み上げることになる。
            // 全部が徒歩なら（車で近づけない目的地）落とさない。案内が空になるより、
            // 歩く指示が混ざるほうがまだ役に立つ。
            let driving = leg.drivingSteps
            // `compactMap(NavStep.init(step:))` と書かないこと。関数として渡すと
            // MainActor の隔離が落ちる（既定で全部が MainActor）。
            steps.append(contentsOf: (driving.isEmpty ? leg.steps : driving).compactMap { NavStep(step: $0) })
            // 最後の区間の終わりは目的地なので、経由地には数えない。
            if index < legs.count - 1 { waypointStepIndices.append(max(steps.count - 1, 0)) }
        }

        // step の座標列を連結して 1 本の線にする。継ぎ目は重複するので落とす。
        var merged: [CLLocationCoordinate2D] = []
        var endIndices: [Int] = []
        for step in steps {
            let isJoin = merged.last.map { $0.isClose(to: step.coordinates[0]) } ?? false
            merged.append(contentsOf: isJoin ? Array(step.coordinates.dropFirst()) : step.coordinates)
            endIndices.append(merged.count - 1)
        }

        // 描画用の線は MKRoute のものをそのまま使う。step から組み直したものより細かい。
        // **ただし徒歩ぶんを落としたときは使えない。** 案内は駐車地点で終わるのに、
        // 線だけが建物の入口まで（階段やエスカレータを通って）伸びる。
        let shape: MKPolyline
        if legs.contains(where: { !$0.walkingSteps.isEmpty }) {
            shape = MKPolyline(coordinates: merged, count: merged.count)
        } else if let only = legs.first, legs.count == 1 {
            shape = only.polyline
        } else {
            let joined = legs.flatMap(\.polyline.coordinates)
            shape = MKPolyline(coordinates: joined, count: joined.count)
        }

        self.init(name: legs.first?.name ?? "",
                  // **残した step から数える。** `MKRoute.distance` は step の合計と
                  // 一致する（実測: 7486m ＝ 車 7270m + 徒歩 215m）ので、そのまま使うと
                  // 歩くぶんが残り距離に混ざる。
                  distance: steps.reduce(0) { $0 + $1.distance },
                  expectedTravelTime: legs.reduce(0) { $0 + $1.drivingTravelTime },
                  polyline: shape,
                  steps: steps,
                  advisoryNotices: legs.flatMap(\.advisoryNotices),
                  destination: destination,
                  waypoints: waypoints,
                  waypointStepIndices: waypointStepIndices,
                  coordinates: merged,
                  stepEndIndices: endIndices)
    }
}

private extension MKRoute {
    /// 末尾に付いてくる徒歩の step。
    ///
    /// **`.automobile` で頼んでも返ってくる。** MapKit は目的地が施設のとき「駐車を準備」で
    /// 車を降ろし、そこから入口まで歩かせる経路を返す（`route.transportType` は
    /// `.automobile` のままなので、`step.transportType` を見ないと区別できない）。
    /// 2026-08-16 の実測では 6 目的地中 4 つで発生し、62〜215m（全体の 1〜7%）。
    ///
    /// このアプリは車を運ぶところまでしか受け持たない（駐車位置から目的地へ歩くぶんを
    /// `DestinationStore` が徒歩の地図へ渡すのと同じ線引き）ので、案内からは落とす。
    var walkingSteps: [MKRoute.Step] { steps.filter { $0.transportType == .walking } }

    /// 車で走る step だけ。
    var drivingSteps: [MKRoute.Step] { steps.filter { $0.transportType != .walking } }

    /// 徒歩ぶんを除いた所要時間。
    ///
    /// **`expectedTravelTime` にも徒歩ぶんが入っている。** MapKit は step ごとの所要時間を
    /// 返さないので、歩く速さを決めて引くしかない。実測では歩行区間の距離を時間差で
    /// 割ると 1.13 m/s（金沢・62m/55秒）と 1.27 m/s（東京タワー・75m/59秒）だったので、
    /// あいだを取って 1.2 m/s とする。効くのは数十秒から 2 分ほど（渋谷の 215m で 152 秒）で、
    /// **運転者がいちばん見る数字がそのぶん遅く出ていた**。
    var drivingTravelTime: TimeInterval {
        let walking = walkingSteps.reduce(0) { $0 + $1.distance }
        return max(expectedTravelTime - walking / MKRoute.walkingSpeed, 0)
    }

    /// 歩く速さ（m/s）。上の実測から。
    static let walkingSpeed: CLLocationSpeed = 1.2
}

private extension NavStep {
    init?(step: MKRoute.Step) {
        let coordinates = step.polyline.coordinates
        // MapKit は先頭に距離 0 の「出発します」ダミー区間を返すことがある。
        guard coordinates.count >= 2 else { return nil }

        self.init(instruction: step.instructions,
                  notice: step.notice,
                  distance: step.distance,
                  coordinates: coordinates)
    }
}

extension MKMultiPoint {
    var coordinates: [CLLocationCoordinate2D] {
        var result = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&result, range: NSRange(location: 0, length: pointCount))
        return result
    }
}

extension CLLocationCoordinate2D {
    /// 継ぎ目判定用。約 10cm 以内なら同じ点とみなす。
    func isClose(to other: CLLocationCoordinate2D) -> Bool {
        abs(latitude - other.latitude) < 1e-6 && abs(longitude - other.longitude) < 1e-6
    }
}
