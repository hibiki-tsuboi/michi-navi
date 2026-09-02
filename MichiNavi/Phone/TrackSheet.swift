import MapKit
import SwiftUI

/// 走った道を線とメッシュで見せる「走破マップ」。
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
        let coverage = ExplorationCoverage.Summary(tracks: store.tracks)
        NavigationStack {
            List {
                if store.tracks.isEmpty {
                    Section { empty }
                } else {
                    Section { map(coverage).listRowInsets(EdgeInsets()) }
                    Section { summary(coverage) }
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
                    Toggle(String(localized: "初めての道や街を読み上げる"), isOn: $advisor.isEnabled)
                    Button(String(localized: "記録を消す"), role: .destructive) { isClearing = true }
                        .disabled(store.tracks.isEmpty && store.visits.isEmpty)
                } footer: {
                    // **記録を切ると県境・街だけ止まる**（市区町村を引くのは記録の側）。
                    // 道は保存済みの履歴と比べられるので、記録の入り切りとは分ける。
                    Text(String(localized: "初めての道へ入る前と、都道府県をまたいだとき、初めて走る市区町村に入ったときに声で知らせます。記録を切ると県境・街の通知は止まります"))
                }
            }
            .navigationTitle(String(localized: "走破マップ"))
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

    /// 走った道の色。**`CarPlayMapViewController.trackColor` と同じ値**（片方だけ変えないこと。
    /// `Core/` は UI に依存しない決まりなので `UIColor` / `Color` を共有できない——
    /// 済んだぶんの灰が 2 か所にあるのと同じ）。
    ///
    /// **青をやめた**（2026-08-24）。この画面には経路が出ないので青でも読めるが、
    /// **同じ線が CarPlay ではマゼンタで出る**ことになる。アプリの中で青は「これから走る道」に
    /// 使っているので、走った道が青いのはここだけ意味が裏返っていた。
    private static let trackColor = Color(red: 0.85, green: 0.2, blue: 0.6).opacity(0.7)
    private static let coverageColor = Color.pink.opacity(0.16)

    private func map(_ coverage: ExplorationCoverage.Summary) -> some View {
        Map(initialPosition: initialPosition, interactionModes: [.pan, .zoom]) {
            ForEach(coverage.cells) { cell in
                MapPolygon(coordinates: cell.coordinates)
                    .foregroundStyle(Self.coverageColor)
            }
            ForEach(store.tracks) { track in
                MapPolyline(coordinates: track.coordinates)
                    .stroke(Self.trackColor, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
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
    private func summary(_ coverage: ExplorationCoverage.Summary) -> some View {
        LabeledContent(String(localized: "走った距離"), value: Formatters.distanceText(store.totalDistance))
        LabeledContent(String(localized: "開拓メッシュ"), value: String(localized: "\(coverage.cells.count) マス"))
        LabeledContent(String(localized: "走破エリア"), value: coverageAreaText(coverage))
        LabeledContent(String(localized: "走った日"), value: String(localized: "\(store.days) 日"))
        LabeledContent(String(localized: "都道府県"), value: prefectureText)
        LabeledContent(String(localized: "市区町村"), value: String(localized: "\(store.visits.count) か所"))
    }

    private func coverageAreaText(_ coverage: ExplorationCoverage.Summary) -> String {
        String.localizedStringWithFormat(String(localized: "約 %.1f km²"), coverage.squareKilometers)
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
            Text(String(localized: "アプリを開いているあいだに走った道とメッシュが、ここに残ります"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
