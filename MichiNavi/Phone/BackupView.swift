import SwiftUI
import UniformTypeIdentifiers

struct BackupView: View {
    @ObservedObject private var service = BackupService.shared
    @ObservedObject private var tracks = TrackStore.shared
    @ObservedObject private var destinations = DestinationStore.shared
    @ObservedObject private var navigation = NavigationController.shared
    @ObservedObject private var sightseeing = SightseeingAdvisor.shared
    @State private var isImporting = false
    @State private var isWorking = false
    @State private var isSharing = false
    @State private var exportURL: URL?
    @State private var sharingError: String?
    @State private var pending: PendingBackup?
    @State private var message: String?
    @State private var didRestore = false

    private struct PendingBackup: Identifiable {
        let id = UUID()
        let archive: BackupArchive
    }

    private var canRestore: Bool {
        navigation.phase == .idle && navigation.activeRoute == nil && !sightseeing.isConnected
    }

    var body: some View {
        List {
            Section {
                Label(String(localized: "次のiPhoneにも、走った道を。"), systemImage: "iphone.gen3.radiowaves.left.and.right")
                    .font(.headline)
                Text(String(localized: "走った道・訪問した街・お気に入り・自宅と職場・目的地履歴・駐車位置・設定を、ひとつのファイルにまとめます。"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "このiPhoneのデータ")) {
                LabeledContent(String(localized: "走った距離"), value: Formatters.distanceText(tracks.totalDistance))
                LabeledContent(String(localized: "訪問した市区町村"), value: tracks.visits.count.formatted())
                LabeledContent(String(localized: "お気に入り"), value: destinations.favorites.count.formatted())
            }

            Section {
                Button(action: export) {
                    Label(String(localized: "バックアップを書き出す"), systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("backup.export")
            } footer: {
                Text(String(localized: "「ファイルに保存」で保管するか、AirDropで新しいiPhoneへ送れます。受け取ったファイルは「ファイル」アプリに保存してください。"))
            }

            Section {
                Button { isImporting = true } label: {
                    Label(String(localized: "バックアップを読み込む"), systemImage: "square.and.arrow.down")
                }
                .disabled(!canRestore)
                .accessibilityIdentifier("backup.import")
            } footer: {
                Text(canRestore
                     ? String(localized: "ファイルを選ぶと内容を確認できます。復元すると、このiPhoneのデータはバックアップの内容にすべて置き換わります。")
                     : String(localized: "読み込みは案内を終了し、CarPlayとの接続を解除してから行ってください。"))
            }

            Section {
                Text(String(localized: "バックアップには移動履歴や自宅などの位置情報が含まれます。ファイル自体にパスワードは付きません。保存先・共有相手を確認してください。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(isWorking || service.isBusy)
        .navigationTitle(String(localized: "バックアップ"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isWorking || service.isBusy)
        .interactiveDismissDisabled(isWorking || service.isBusy)
        .overlay {
            if isWorking || service.isBusy {
                ProgressView(String(localized: "データを準備中…"))
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            switch result {
            case let .success(url): read(url)
            case let .failure(error): show(error)
            }
        }
        .sheet(isPresented: $isSharing, onDismiss: removeExport) {
            if let exportURL {
                BackupShareSheet(url: exportURL) { error in
                    sharingError = error?.localizedDescription
                    isSharing = false
                }
            }
        }
        .sheet(item: $pending, onDismiss: {
            if didRestore {
                didRestore = false
                message = String(localized: "バックアップを復元しました。走破マップやお気に入りをご確認ください。")
            }
        }) { backup in
            BackupRestorePreview(archive: backup.archive) {
                try await service.restore(backup.archive)
                didRestore = true
                pending = nil
            }
        }
        .alert(String(localized: "バックアップ"), isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } }
        )) {
            Button(String(localized: "閉じる"), role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private func export() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let data = try await service.export()
                exportURL = try await Task.detached { try BackupFiles.prepareExport(data) }.value
                isSharing = true
            } catch { show(error) }
        }
    }

    private func read(_ url: URL) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let archive = try await Task.detached { try BackupFiles.read(url) }.value
                pending = PendingBackup(archive: archive)
            } catch { show(error) }
        }
    }

    private func removeExport() {
        if let exportURL { BackupFiles.removeExport(exportURL) }
        exportURL = nil
        if let sharingError { message = sharingError }
        sharingError = nil
    }

    private func show(_ error: Error) {
        let cocoaError = error as NSError
        guard cocoaError.domain != NSCocoaErrorDomain || cocoaError.code != NSUserCancelledError else { return }
        message = error.localizedDescription
    }
}

private struct BackupRestorePreview: View {
    let archive: BackupArchive
    let restore: () async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirming = false
    @State private var isRestoring = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section(String(localized: "バックアップの内容")) {
                    LabeledContent(String(localized: "作成日時")) {
                        Text(archive.createdAt, format: .dateTime.year().month().day().hour().minute())
                    }
                    LabeledContent(String(localized: "走行記録の地点"), value: archive.pointCount.formatted())
                    LabeledContent(String(localized: "訪問した市区町村"), value: archive.visits.count.formatted())
                    LabeledContent(String(localized: "お気に入り"), value: archive.destinations.favorites.count.formatted())
                    LabeledContent(String(localized: "目的地履歴"), value: archive.destinations.recents.count.formatted())
                    LabeledContent(String(localized: "自宅"), value: archive.destinations.home?.name ?? String(localized: "未設定"))
                    LabeledContent(String(localized: "職場"), value: archive.destinations.work?.name ?? String(localized: "未設定"))
                    LabeledContent(String(localized: "駐車位置"), value: archive.destinations.parking?.place.name ?? String(localized: "未設定"))
                }
                Section {
                    Button(String(localized: "このバックアップで復元"), role: .destructive) { isConfirming = true }
                        .accessibilityIdentifier("backup.restore")
                } footer: {
                    Text(String(localized: "走行記録・保存した地点・設定をすべて置き換えます。現在のデータも残したい場合は、先にバックアップを書き出してください。"))
                }
            }
            .disabled(isRestoring)
            .navigationTitle(String(localized: "復元内容の確認"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "キャンセル")) { dismiss() }.disabled(isRestoring)
                }
            }
            .overlay {
                if isRestoring { ProgressView(String(localized: "復元中…")) }
            }
            .confirmationDialog(String(localized: "現在のデータを置き換えますか？"),
                                isPresented: $isConfirming, titleVisibility: .visible) {
                Button(String(localized: "置き換えて復元"), role: .destructive) {
                    isRestoring = true
                    Task {
                        defer { isRestoring = false }
                        do { try await restore() }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
            }
            .alert(String(localized: "復元できませんでした"), isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button(String(localized: "閉じる"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .interactiveDismissDisabled(isRestoring)
    }
}

private struct BackupShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onCompletion: @MainActor (Error?) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, error in
            Task { @MainActor in onCompletion(error) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
