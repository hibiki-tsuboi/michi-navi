import MapKit
import SwiftUI

/// iPhone 側の目的地検索。CarPlay の `CPSearchTemplate` と同じ
/// `SearchService` を使うので、候補の出方が両画面で揃う。
struct SearchSheet: View {
    let onSelect: (Place) -> Void

    @Environment(\.dismiss) private var dismiss
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

                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        select(suggestion)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title).foregroundStyle(.primary)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(isResolving)
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
