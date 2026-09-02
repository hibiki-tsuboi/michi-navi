import Combine
import MapKit
import SwiftUI

/// iPhone 側の画面。CarPlay と同じ `NavigationController` を見ているので、
/// どちらで目的地を決めても両方の画面がついてくる。
struct ContentView: View {
    @EnvironmentObject private var navigation: NavigationController
    @ObservedObject private var location = LocationService.shared
    @ObservedObject private var store = DestinationStore.shared
    @ObservedObject private var tracks = TrackStore.shared

    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var isSearchPresented = false
    @State private var isTrackPresented = false
    @State private var isExplorationPresented = false
    @State private var errorMessage: String?
    /// 検索シートを「行き先を選ぶ」ではなく「ピン留めを設定する」ために開いているか。
    @State private var assigningPin: DestinationStore.Pinned?

    var body: some View {
        Map(position: $cameraPosition) {
            UserAnnotation()

            if let route = displayedRoute {
                MapPolyline(route.polyline)
                    .stroke(.blue, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                // 通ってきたところを塗り替える（CarPlay と同じ）。**あとに書くほど上に描かれる**
                // ので、経路の線より下に置かないこと。色は不透明でなければならない
                // （透かしても下の青が出るだけ）。太さも同じ 6pt にする。
                //
                // **間引いていない。** CarPlay 側が 50m ごとにしか引き直さないのは
                // `MKOverlay` を差し替える手間があるからで、こちらは `progress` が来るたびに
                // body が走る以上、間引いても計算する回数は変わらない。
                if case .navigating = navigation.phase, let progress = navigation.progress {
                    MapPolyline(coordinates: route.travelled(remaining: progress.distanceRemaining))
                        .stroke(Self.travelledColor,
                                style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                }
                // 立ち寄り先は目的地と見分けが付くよう別の印にする。
                ForEach(route.displayedWaypoints) { waypoint in
                    Marker(waypoint.name, systemImage: "mappin.and.ellipse", coordinate: waypoint.coordinate)
                        .tint(.orange)
                }
                Marker(route.destination.name, coordinate: route.destination.coordinate)
            }
        }
        // 渋滞を出す。どのルートを選ぶかの判断材料になるので、候補を見せる画面にこそ要る。
        .mapStyle(.standard(showsTraffic: true))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .safeAreaInset(edge: .top) { topBar }
        .safeAreaInset(edge: .bottom) { bottomPanel }
        .sheet(isPresented: $isSearchPresented) {
            SearchSheet(title: assigningPin?.title ?? String(localized: "目的地")) { place in
                isSearchPresented = false
                // ピン留めを設定しに来たときは、案内を始めない。設定と発進は別の操作。
                if let assigningPin {
                    store.set(place, as: assigningPin)
                    self.assigningPin = nil
                } else {
                    navigation.requestRoutes(to: place)
                }
            }
        }
        .sheet(isPresented: $isTrackPresented) { TrackSheet() }
        .sheet(isPresented: $isExplorationPresented) {
            ExplorationDriveSheet { duration in
                isExplorationPresented = false
                navigation.requestExplorationRoutes(duration: duration)
            }
        }
        .onChange(of: isSearchPresented) { _, presented in
            // シートを閉じただけのときに、次に開いた検索が設定モードのまま始まらないように。
            if !presented { assigningPin = nil }
        }
        .onChange(of: navigation.phase) { _, phase in
            // ルートが出たら全体が見えるよう引き、案内が始まったら自車に寄る。
            switch phase {
            case .previewing:
                if let route = displayedRoute {
                    cameraPosition = .rect(route.polyline.boundingMapRect.padded(by: 1.4))
                }
            case .navigating:
                cameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
            default:
                break
            }
        }
        .onReceive(navigation.$lastError.compactMap { $0 }) { errorMessage = $0 }
        .alert(String(localized: "計算できませんでした"),
               isPresented: Binding(
                   get: { errorMessage != nil },
                   set: { if !$0 { errorMessage = nil } }
               )) {
            Button(String(localized: "閉じる"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// 通ってきたところの色。**`CarPlayMapViewController.travelledColor` と同じ値**
    /// （片方だけ変えないこと）。昼夜で入れ替わる動的な色を使わない理由もあちらに書いてある。
    private static let travelledColor = Color(white: 0.45)

    private var displayedRoute: NavRoute? {
        switch navigation.phase {
        case let .previewing(routes): routes.first
        case let .navigating(route): route
        default: nil
        }
    }

    // MARK: - 上部

    @ViewBuilder
    private var topBar: some View {
        if case let .navigating(route) = navigation.phase {
            // バナー自体を読み直しのボタンにする。運転中に押す先は大きいほどよく、
            // ここは画面でいちばん大きい要素なので、専用のボタンを足すより当てやすい。
            Button {
                VoiceGuidance.shared.repeatCurrentGuidance()
            } label: {
                ManeuverBanner(route: route, progress: navigation.progress)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "案内をもう一度読む"))
            .padding(.horizontal)
        } else {
            VStack(spacing: 8) {
                Button {
                    isSearchPresented = true
                } label: {
                    HStack {
                        Image(systemName: "magnifyingglass")
                        Text(String(localized: "目的地を検索"))
                        Spacer()
                    }
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .foregroundStyle(.secondary)

                pinnedDestinations
            }
            .padding(.horizontal)
        }
    }

    /// 自宅・職場。**設定していなくても枠を出す**。
    ///
    /// 空の枠がそのまま設定の入口になるので、「どこで設定するのか」を探さずに済む。
    ///
    /// **設定し直しと解除は「…」で出す**（2026-08-23）。それまでは長押しの中だけに
    /// 置いていて、**画面に手がかりが 1 つも無かった**——見つからないものは、無いのと
    /// 同じ。隠した理由は「運転中に触るものではないから」だったが、**iPhone の画面は
    /// 運転中に使わない**（そのための CarPlay）ので、隠して得るものが無かった。
    /// 長押しのほうも残してある。
    private var pinnedDestinations: some View {
        HStack(spacing: 8) {
            ForEach(DestinationStore.Pinned.allCases, id: \.self) { kind in
                pinnedChip(kind)
            }
        }
    }

    /// 枠 1 つ。**押す＝そこへ向かう**は変えない。編集は右端の「…」に分ける。
    @ViewBuilder
    private func pinnedChip(_ kind: DestinationStore.Pinned) -> some View {
        let place = store.place(kind)
        HStack(spacing: 0) {
            Button {
                if let place {
                    navigation.requestRoutes(to: place)
                } else {
                    assign(kind)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: kind.symbol)
                    // 設定済みなら名札を主役に、どこを指しているかは添えるだけ
                    // （CarPlay のピンの行と同じ形）。
                    VStack(alignment: .leading, spacing: 1) {
                        Text(place == nil ? String(localized: "\(kind.title)を設定") : kind.title)
                            .lineLimit(1)
                        if let place {
                            Text(place.name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
                .padding(.leading, 12)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(place == nil ? .secondary : .primary)

            // 未設定の枠には出さない。押す先（設定）が枠そのものと同じになるので、
            // 選ぶものが 1 つしかないメニューになる。
            if place != nil {
                Menu {
                    Button(String(localized: "設定し直す")) { assign(kind) }
                    Button(String(localized: "解除"), role: .destructive) {
                        store.set(nil, as: kind)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .contentShape(.rect)
                }
                .foregroundStyle(.secondary)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            Button(String(localized: "設定し直す")) { assign(kind) }
            if place != nil {
                Button(String(localized: "解除"), role: .destructive) {
                    store.set(nil, as: kind)
                }
            }
        }
    }

    /// 検索シートを「ピン留めを設定する」ために開く。
    private func assign(_ kind: DestinationStore.Pinned) {
        assigningPin = kind
        isSearchPresented = true
    }

    // MARK: - 下部

    @ViewBuilder
    private var bottomPanel: some View {
        switch navigation.phase {
        case .idle:
            VStack(spacing: 8) {
                if let arrival = navigation.arrivalHarvest {
                    ArrivalHarvestCard(
                        arrival: arrival,
                        onOpenTracks: {
                            navigation.dismissArrivalHarvest()
                            isTrackPresented = true
                        },
                        onDismiss: navigation.dismissArrivalHarvest
                    )
                }
                if location.authorizationStatus == .denied || location.authorizationStatus == .restricted {
                    notice(String(localized: "設定アプリで位置情報の利用を許可してください"))
                }
                explorationRow
                trackRow
            }

        case let .calculating(place):
            HStack(spacing: 12) {
                ProgressView()
                if navigation.explorationTargetDuration != nil {
                    Text(String(localized: "探索ルートを計算中…"))
                } else {
                    Text(String(localized: "\(place.name) までのルートを計算中…"))
                }
                Spacer()
                Button(String(localized: "中止")) { navigation.cancelNavigation() }
            }
            .panel()

        case let .previewing(routes):
            if let route = routes.first {
                VStack(alignment: .leading, spacing: 12) {
                    Text(previewTitle(for: route)).font(.headline)
                    Text(Formatters.routeSummary(distance: route.distance, duration: route.expectedTravelTime))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    let brief = route.driveBrief ?? DriveBrief.make(
                        for: route,
                        comparisonTags: RouteCharacter.tags(for: routes).first ?? [],
                        departure: Date()
                    )
                    DriveBriefCard(brief: brief)
                    if !route.isExplorationLoop {
                        DepartureTimeRow(destination: route.destination)
                    }

                    HStack {
                        Button(String(localized: "やめる")) { navigation.cancelNavigation() }
                            .buttonStyle(.bordered)
                        Button(String(localized: "案内開始")) { navigation.startNavigation(with: route) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .panel()
            }

        case .navigating:
            HStack {
                if let progress = navigation.progress {
                    VStack(alignment: .leading) {
                        Text(Formatters.durationText(progress.timeRemaining)).font(.title3.bold())
                        Text(String(localized: "\(Formatters.distanceText(progress.distanceRemaining))・\(Formatters.arrivalText(progress.arrivalDate)) 着"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let newRoad = navigation.newRoadProgress {
                            Label(newRoadText(newRoad), systemImage: "sparkles")
                                .font(.caption)
                                .foregroundStyle(.pink)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer()
                Button(String(localized: "案内終了"), role: .destructive) { navigation.cancelNavigation() }
                    .buttonStyle(.bordered)
            }
            .panel()
        }
    }

    private func previewTitle(for route: NavRoute) -> String {
        guard let duration = route.explorationDuration else { return route.destination.name }
        return String(localized: "探索ドライブ・\(Formatters.durationText(duration))コース")
    }

    private func newRoadText(_ progress: RouteNovelty.Profile.Progress) -> String {
        switch progress {
        case let .approaching(distance):
            String(localized: "初めての道まで\(Formatters.distanceText(distance))")
        case let .exploring(distance):
            String(localized: "初めての道を\(Formatters.distanceText(distance))走行")
        }
    }

    /// 行き先を決めずに走る入口。時間を選ぶところまでを停車中の iPhone で済ませる。
    private var explorationRow: some View {
        Button {
            isExplorationPresented = true
        } label: {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.pink)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "探索ドライブ"))
                    Text(String(localized: "時間を選んで、初めての道が多い周回コースへ"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .panel()
    }

    /// 走破マップへの入口。**待機中の下がここまで空いていた**うえ、走った距離がそのまま
    /// 「開く理由」になる。目的地の無い日にカーナビを開くのは、ふつうこれしか無い。
    private var trackRow: some View {
        Button {
            isTrackPresented = true
        } label: {
            HStack {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "走破マップ"))
                    Text(tracks.tracks.isEmpty
                         ? String(localized: "まだ記録がありません")
                         : Formatters.distanceText(tracks.totalDistance))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .panel()
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
    }

}

/// 探索ドライブの長さだけを決める。周回の方角と道路は履歴を見てアプリが選ぶ。
private struct ExplorationDriveSheet: View {
    let onSelect: (TimeInterval) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(String(localized: "現在地へ戻る周回コースを、初めての道が多い順に探します"))
                    .foregroundStyle(.secondary)

                ForEach(ExplorationDrive.durationOptions, id: \.self) { duration in
                    Button {
                        onSelect(duration)
                    } label: {
                        HStack {
                            Image(systemName: "clock")
                            Text(String(localized: "約\(Formatters.durationText(duration))"))
                                .font(.headline)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(.pink)
                }

                Text(String(localized: "実際の所要時間は道路状況により前後します"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle(String(localized: "探索ドライブ"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "閉じる")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - 到着後の収穫

/// 到着したあとにだけ残る、ひと走りの成果。走行中に読む画面ではないので iPhone に出し、
/// 詳しい履歴は既存の「走った道」へつなぐ。初めての土地が無い走行では生成されない。
private struct ArrivalHarvestCard: View {
    let arrival: NavigationController.ArrivalHarvest
    let onOpenTracks: () -> Void
    let onDismiss: () -> Void

    private var harvest: TripSummary.Harvest { arrival.harvest }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(String(localized: "今回の収穫"), systemImage: "sparkles")
                        .font(.headline)
                        .foregroundStyle(.pink)
                    Text(String(localized: "\(arrival.destinationName)周辺までのドライブ"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "閉じる"))
            }

            HStack(alignment: .top, spacing: 12) {
                if let prefecture = harvest.prefecture {
                    harvestMetric(value: prefecture,
                                  label: String(localized: "初めて走った都道府県"),
                                  symbol: "map.fill")
                }
                harvestMetric(value: String(localized: "\(harvest.cities)か所"),
                              label: String(localized: "初めて走った街"),
                              symbol: "building.2.fill")
            }

            HStack {
                Label(
                    String(localized: "通算\(harvest.totalPrefectures)都道府県・\(harvest.totalCities)市区町村"),
                    systemImage: "flag.checkered"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "走破マップを見る"), action: onOpenTracks)
                    .font(.caption.bold())
            }
        }
        .panel()
        .accessibilityElement(children: .contain)
    }

    private func harvestMetric(value: String, label: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.pink)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title3.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - ドライブブリーフ

/// 出発前に見る要点。最初は開いておき、地図を広く見たいときだけ畳めるようにする。
private struct DriveBriefCard: View {
    let brief: DriveBrief

    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(brief.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.symbolName)
                            .frame(width: 18)
                            .foregroundStyle(color(for: item.kind))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(.caption.bold())
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label(String(localized: "ドライブブリーフ"), systemImage: "car.side.fill")
                .font(.subheadline.bold())
        }
    }

    private func color(for kind: DriveBrief.Item.Kind) -> Color {
        switch kind {
        case .sunlight, .advisory: .orange
        case .waypoint: .purple
        case .novelty, .comparison, .turns: .accentColor
        }
    }
}

// MARK: - 出発時刻の逆算

/// 「何時に着きたいか」から出発時刻を出す。
///
/// **iPhone にしか置いていない。** 車に乗ってから「何時に出ればいいか」を知っても
/// もう遅く、これは出かける前に見る数字だから。CarPlay に置くと、運転中に
/// DatePicker を回させることにもなる。
private struct DepartureTimeRow: View {
    let destination: Place

    @EnvironmentObject private var navigation: NavigationController
    @State private var isExpanded = false
    @State private var arrival = Date(timeIntervalSinceNow: 3600)
    @State private var departure: Date?
    @State private var isCalculating = false

    var body: some View {
        DisclosureGroup(String(localized: "到着時刻から逆算"), isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                DatePicker(String(localized: "着きたい時刻"), selection: $arrival, displayedComponents: [.date, .hourAndMinute])
                    .font(.subheadline)

                if isCalculating {
                    ProgressView().controlSize(.small)
                } else if let departure {
                    Text(String(localized: "\(Formatters.arrivalText(departure)) に出発"))
                        .font(.subheadline.bold())
                } else {
                    Text(String(localized: "計算できませんでした")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
        .font(.subheadline)
        .onChange(of: arrival) { _, _ in calculate() }
        .onChange(of: isExpanded) { _, expanded in if expanded { calculate() } }
    }

    private func calculate() {
        guard isExpanded else { return }
        isCalculating = true
        Task {
            departure = await navigation.departureTime(toArriveBy: arrival, at: destination)
            isCalculating = false
        }
    }
}

// MARK: - 次の指示バナー

private struct ManeuverBanner: View {
    let route: NavRoute
    let progress: RouteProgress?

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "arrow.turn.up.right")
                .font(.system(size: 32, weight: .semibold))

            VStack(alignment: .leading, spacing: 2) {
                if let progress {
                    Text(Formatters.distanceText(progress.distanceToNextManeuver))
                        .font(.title2.bold())
                    Text(instruction(at: progress.stepIndex))
                        .font(.subheadline)
                        .lineLimit(2)
                    if let notice = notice(at: progress.stepIndex) {
                        Text(notice)
                            .font(.caption)
                            .opacity(0.85)
                            .lineLimit(1)
                    }
                } else {
                    Text(String(localized: "案内を開始しています…")).font(.subheadline)
                }
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .padding()
        .background(.blue, in: RoundedRectangle(cornerRadius: 16))
    }

    private func instruction(at index: Int) -> String {
        route.steps.indices.contains(index) ? route.steps[index].instruction : String(localized: "目的地に向かっています")
    }

    /// 区間ごとの注意（料金所・車線規制など）。CarPlay 側は割り込みで出すが、
    /// iPhone は運転中に見る前提ではないので、指示の下に添えるだけにする。
    private func notice(at index: Int) -> String? {
        guard route.steps.indices.contains(index) else { return nil }
        return route.steps[index].notice
    }
}

// MARK: - 共通の見た目

private extension View {
    func panel() -> some View {
        padding()
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)
    }
}

extension MKMapRect {
    /// ルート全体を表示するときの余白。**`TrackSheet` も使う**ので file-private にしない。
    func padded(by factor: Double) -> MKMapRect {
        let widthDelta = size.width * (factor - 1) / 2
        let heightDelta = size.height * (factor - 1) / 2
        return insetBy(dx: -widthDelta, dy: -heightDelta)
    }
}

#Preview {
    ContentView().environmentObject(NavigationController.shared)
}
