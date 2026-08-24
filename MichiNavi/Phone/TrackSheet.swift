import MapKit
import SwiftUI

/// 走った道を見せる画面。
///
/// **iPhone にしか出さない。** 運転席から見るものではないし、CarPlay の画面で
/// 眺めさせるものでもない（走行中に読める行数は限られる、という制約がそのまま効く）。
/// 駐車位置を CarPlay に出していないのと同じ理由。
struct TrackSheet: View {
    @ObservedObject private var store = TrackStore.shared
    @ObservedObject private var advisor = VisitAdvisor.shared
    @Environment(\.dismiss) private var dismiss

    @State private var isClearing = false

    var body: some View {
        NavigationStack {
            List {
                if store.tracks.isEmpty {
                    Section { empty }
                } else {
                    Section { map.listRowInsets(EdgeInsets()) }
                    Section { summary }
                }

                ForEach(store.visitsByPrefecture, id: \.prefecture) { group in
                    Section(group.prefecture) {
                        ForEach(group.cities) { visit in
                            LabeledContent(visit.city) {
                                Text(visit.first, style: .date).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    Toggle(String(localized: "走った道を記録する"), isOn: $store.isRecording)
                    Toggle(String(localized: "県境と初めての街を読み上げる"), isOn: $advisor.isEnabled)
                    Button(String(localized: "記録を消す"), role: .destructive) { isClearing = true }
                        .disabled(store.tracks.isEmpty && store.visits.isEmpty)
                } footer: {
                    // **記録を切ると読み上げも止まる**（市区町村を引くのは記録の側）。
                    // 画面に出さないと、切ったことと鳴らないことが結びつかない。
                    Text(String(localized: "都道府県をまたいだときと、初めて走る市区町村に入ったときに声で知らせます。記録を切ると鳴りません"))
                }
            }
            .navigationTitle(String(localized: "走った道"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "閉じる")) { dismiss() }
                }
            }
            .confirmationDialog(String(localized: "走った道の記録をすべて消しますか"),
                                isPresented: $isClearing, titleVisibility: .visible) {
                Button(String(localized: "消す"), role: .destructive) { store.clear() }
            }
        }
    }

    private var map: some View {
        Map(initialPosition: initialPosition, interactionModes: [.pan, .zoom]) {
            ForEach(store.tracks) { track in
                MapPolyline(coordinates: track.coordinates)
                    .stroke(.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(height: 280)
    }

    /// 走ったところ全部が入る位置。**一度きりで、あとは指に任せる**
    /// （`initialPosition` なので描き直しで引き戻されない）。
    private var initialPosition: MapCameraPosition {
        let points = store.tracks.flatMap(\.coordinates).map { MKMapRect(origin: MKMapPoint($0), size: MKMapSize()) }
        guard let first = points.first else { return .automatic }
        return .rect(points.dropFirst().reduce(first) { $0.union($1) }.padded(by: 1.3))
    }

    @ViewBuilder
    private var summary: some View {
        LabeledContent(String(localized: "走った距離"), value: Formatters.distanceText(store.totalDistance))
        LabeledContent(String(localized: "走った日"), value: String(localized: "\(store.days) 日"))
        LabeledContent(String(localized: "都道府県"), value: prefectureText)
        LabeledContent(String(localized: "市区町村"), value: String(localized: "\(store.visits.count) か所"))
    }

    /// **分母を出すのは日本だけ。** 47 という数はここでしか通じないし、市区町村のほうは
    /// 合併で変わるので分母を持たない（数と名前だけ出す）。
    private var prefectureText: String {
        guard Locale.current.region?.identifier == "JP" else { return "\(store.prefectureCount)" }
        return String(localized: "47 のうち \(store.prefectureCount)")
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "まだ記録がありません"))
            Text(String(localized: "アプリを開いているあいだに走った道が、ここに残ります"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
