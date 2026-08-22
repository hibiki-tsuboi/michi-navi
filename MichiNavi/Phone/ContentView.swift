import MapKit
import SwiftUI
import UIKit

/// iPhone 側の画面。CarPlay と同じ `NavigationController` を見ているので、
/// どちらで目的地を決めても両方の画面がついてくる。
struct ContentView: View {
    @EnvironmentObject private var navigation: NavigationController
    @ObservedObject private var location = LocationService.shared
    @ObservedObject private var store = DestinationStore.shared

    @State private var cameraPosition: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var isSearchPresented = false
    /// 検索シートを「行き先を選ぶ」ではなく「ピン留めを設定する」ために開いているか。
    @State private var assigningPin: DestinationStore.Pinned?

    var body: some View {
        Map(position: $cameraPosition) {
            UserAnnotation()

            if let route = displayedRoute {
                MapPolyline(route.polyline)
                    .stroke(.blue, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                // 立ち寄り先は目的地と見分けが付くよう別の印にする。
                ForEach(route.waypoints) { waypoint in
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
    }

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
    /// ここでしか設定できない（CarPlay 側は検索が使えず設定できない）ぶん、
    /// 入口は見えているほうがよい。
    private var pinnedDestinations: some View {
        HStack(spacing: 8) {
            ForEach(DestinationStore.Pinned.allCases, id: \.self) { kind in
                let place = store.place(kind)
                Button {
                    if let place {
                        navigation.requestRoutes(to: place)
                    } else {
                        assigningPin = kind
                        isSearchPresented = true
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: kind.symbol)
                        Text(place == nil ? String(localized: "\(kind.title)を設定") : kind.title)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .foregroundStyle(place == nil ? .secondary : .primary)
                .contextMenu {
                    // 設定し直しと解除は運転中に触るものではないので、長押しの奥に置く。
                    Button(String(localized: "設定し直す")) {
                        assigningPin = kind
                        isSearchPresented = true
                    }
                    if place != nil {
                        Button(String(localized: "解除"), role: .destructive) {
                            store.set(nil, as: kind)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 下部

    @ViewBuilder
    private var bottomPanel: some View {
        switch navigation.phase {
        case .idle:
            if location.authorizationStatus == .denied || location.authorizationStatus == .restricted {
                notice(String(localized: "設定アプリで位置情報の利用を許可してください"))
            }

        case let .calculating(place):
            HStack(spacing: 12) {
                ProgressView()
                Text(String(localized: "\(place.name) までのルートを計算中…"))
                Spacer()
                Button(String(localized: "中止")) { navigation.cancelNavigation() }
            }
            .panel()

        case let .previewing(routes):
            if let route = routes.first {
                VStack(alignment: .leading, spacing: 12) {
                    Text(route.destination.name).font(.headline)
                    Text(Formatters.routeSummary(distance: route.distance, duration: route.expectedTravelTime))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    characterTags(RouteCharacter.tags(for: routes).first ?? [])
                    advisories(route.advisoryNotices)
                    DepartureTimeRow(destination: route.destination)

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
            VStack(spacing: 8) {
                backgroundLocationNotice
                navigatingPanel
            }
        }
    }

    private var navigatingPanel: some View {
        HStack {
            if let progress = navigation.progress {
                VStack(alignment: .leading) {
                    Text(Formatters.durationText(progress.timeRemaining)).font(.title3.bold())
                    Text(String(localized: "\(Formatters.distanceText(progress.distanceRemaining))・\(Formatters.arrivalText(progress.arrivalDate)) 着"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(String(localized: "案内終了"), role: .destructive) { navigation.cancelNavigation() }
                .buttonStyle(.bordered)
        }
        .panel()
    }

    /// 「使用中のみ」で案内しているあいだ、出しっぱなしにする注意。
    ///
    /// **一度きりの表示にしない。** 直すには設定アプリへ行く必要があり、戻ってきたときに
    /// 消えていると何を直しに行ったのか分からなくなる。許可が変われば自然に消える。
    ///
    /// **設定を開くボタンはこちらにしか無い。** CarPlay 側は起きることを伝えるだけで、
    /// 押させる操作を作っていない（運転中に iPhone を触らせないため）。
    @ViewBuilder
    private var backgroundLocationNotice: some View {
        if location.authorizationStatus == .authorizedWhenInUse {
            HStack(spacing: 12) {
                Image(systemName: "location.slash")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "位置情報が「使用中のみ」です"))
                        .font(.footnote.bold())
                    Text(String(localized: "ほかのアプリに切り替えると案内が止まります"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "設定")) { openLocationSettings() }
                    .buttonStyle(.bordered)
            }
            .panel()
        }
    }

    private func openLocationSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
    }

    /// 候補どうしを比べて分かる特徴。候補が 1 本しか無ければ何も出ない。
    @ViewBuilder
    private func characterTags(_ tags: [String]) -> some View {
        if !tags.isEmpty {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.tint.opacity(0.15), in: Capsule())
                }
            }
        }
    }

    /// MapKit がルートに付けてくる注意（有料道路・通行規制など）。
    /// どのルートを選ぶかの判断材料になるので、候補を見せる場所で出す。
    @ViewBuilder
    private func advisories(_ notices: [String]) -> some View {
        if !notices.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(notices, id: \.self) { notice in
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
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

private extension MKMapRect {
    /// ルート全体を表示するときの余白。
    func padded(by factor: Double) -> MKMapRect {
        let widthDelta = size.width * (factor - 1) / 2
        let heightDelta = size.height * (factor - 1) / 2
        return insetBy(dx: -widthDelta, dy: -heightDelta)
    }
}

#Preview {
    ContentView().environmentObject(NavigationController.shared)
}
