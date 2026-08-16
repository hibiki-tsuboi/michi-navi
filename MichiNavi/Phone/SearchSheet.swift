import MapKit
import SwiftUI

/// iPhone 側の目的地検索。CarPlay の `CPSearchTemplate` と同じ
/// `SearchService` を使うので、候補の出方が両画面で揃う。
///
/// 入力が空のときはお気に入りと履歴を出す。CarPlay では走行中にキーボードが
/// 塞がれるため、ここでお気に入りを育てておくことが実質の前提になる。
struct SearchSheet: View {
    let onSelect: (Place) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = DestinationStore.shared
    @ObservedObject private var preferences = RoutePreferences.shared

    @State private var query = ""
    @State private var suggestions: [MKLocalSearchCompletion] = []
    @State private var isResolving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }

                if query.isEmpty {
                    parkedCar
                    routePreferences
                    savedDestinations
                } else {
                    suggestionRows
                }
            }
            .searchable(text: $query, prompt: "住所・施設名で検索")
            .navigationTitle("目的地")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .overlay {
                if isResolving { ProgressView() }
            }
            .onChange(of: query) { _, text in
                SearchService.shared.suggest(text, near: currentRegion) { suggestions = $0 }
            }
        }
    }

    // MARK: - 車をとめた場所

    /// 案内を終えた地点＝車を置いた場所。
    ///
    /// **ここへの案内はこのアプリでやらない。** 歩いて戻る場面なので、徒歩の経路を
    /// 持っているマップへ渡す。カーナビが車で車を迎えに行く経路を出しても意味がない。
    @ViewBuilder
    private var parkedCar: some View {
        if let parking = store.parking {
            Section("車をとめた場所") {
                Button {
                    parking.place.mapItem.openInMaps(launchOptions: [
                        MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking,
                    ])
                } label: {
                    HStack {
                        summary(name: "ここまで歩いて戻る",
                                detail: parking.date.formatted(date: .omitted, time: .shortened) + " にとめました")
                        Image(systemName: "figure.walk").foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                Button("記録を消す", role: .destructive) { store.clearParking() }
            }
        }
    }

    // MARK: - ルートの引き方

    /// 目的地を選ぶ手前に置く。ここを変えると返ってくる経路そのものが変わるので、
    /// 選んだあとに気づいても遅い。**走っている案内は引き直さない**（次の計算から効く）。
    private var routePreferences: some View {
        Section("ルートの引き方") {
            Toggle("有料道路を避ける", isOn: $preferences.avoidsTolls)
            Toggle("高速道路を避ける", isOn: $preferences.avoidsHighways)
        }
    }

    // MARK: - お気に入りと履歴

    @ViewBuilder
    private var savedDestinations: some View {
        if store.favorites.isEmpty, store.recents.isEmpty {
            ContentUnavailableView("目的地の履歴はまだありません",
                                   systemImage: "mappin.slash",
                                   description: Text("案内を始めるとここに残ります。\n星を付けると CarPlay のお気に入りに並びます。"))
        } else {
            if !store.favorites.isEmpty {
                Section("お気に入り") {
                    ForEach(store.favorites) { place in row(for: place) }
                }
            }

            if !store.recents.isEmpty {
                Section("最近の目的地") {
                    ForEach(store.recents) { place in row(for: place) }
                }
            }
        }
    }

    private func row(for place: Place) -> some View {
        HStack(spacing: 12) {
            Button {
                onSelect(place)
            } label: {
                summary(name: place.name, detail: place.subtitle)
            }
            .buttonStyle(.plain)
            .disabled(isResolving)

            Button {
                store.toggleFavorite(place)
            } label: {
                let isFavorite = store.isFavorite(place)
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(store.isFavorite(place) ? "お気に入りから外す" : "お気に入りに追加")
        }
    }

    // MARK: - 入力中の候補

    private var suggestionRows: some View {
        ForEach(suggestions, id: \.self) { suggestion in
            Button {
                select(suggestion)
            } label: {
                summary(name: suggestion.title, detail: suggestion.subtitle)
            }
            .buttonStyle(.plain)
            .disabled(isResolving)
        }
    }

    private func summary(name: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).foregroundStyle(.primary)
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func select(_ suggestion: MKLocalSearchCompletion) {
        isResolving = true
        errorMessage = nil

        Task {
            defer { isResolving = false }
            do {
                let places = try await SearchService.shared.resolve(suggestion)
                guard let place = places.first else {
                    errorMessage = "場所が特定できませんでした"
                    return
                }
                onSelect(place)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var currentRegion: MKCoordinateRegion? {
        guard let coordinate = LocationService.shared.location?.coordinate else { return nil }
        return MKCoordinateRegion(center: coordinate, latitudinalMeters: 20_000, longitudinalMeters: 20_000)
    }
}
