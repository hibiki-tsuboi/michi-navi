import CarPlay
import MapKit

/// CarPlay の音声入力。押して話す → 聞き取り → 読み解き → 検索、までを一続きで面倒を見る。
///
/// **走行中はキーボードが塞がれる**ので、これが「新しい行き先をその場で決める」唯一の道になる。
/// お気に入り・履歴・周辺カテゴリは、あらかじめ知っている場所にしか届かない。
///
/// `CPVoiceControlTemplate` を出しているあいだが「音声サービスが動いている」時間で、
/// ガイド p.27 はその間ずっとこの画面を出しておくことを求めている。だから聞き取りだけでなく
/// 検索が終わるまで畳まない。
///
/// なお**このテンプレートは、いまナビアプリだけが使える**。ガイド p.14 の対応表で
/// 他のカテゴリには「iOS 27 以降」の注が付いている。
@MainActor
final class CarPlayVoiceControl {
    /// 画面に出す状態。5 つまでという制限があるが、使うのは 2 つ。
    private enum Step: String {
        case listening
        case searching
    }

    private enum Failure: LocalizedError {
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case let .notFound(query): "「\(query)」は見つかりませんでした"
            }
        }
    }

    private let interfaceController: CPInterfaceController
    private let onSelect: (CarPlayDestinationBrowser.Choice) -> Void
    private let onError: (String) -> Void

    private let search = SearchService.shared
    private let store = DestinationStore.shared
    private let location = LocationService.shared

    /// 二重に走らせない。ボタンの連打と、CarPlay 側の再入の両方を止める。
    private var isRunning = false

    init(interfaceController: CPInterfaceController,
         onSelect: @escaping (CarPlayDestinationBrowser.Choice) -> Void,
         onError: @escaping (String) -> Void) {
        self.interfaceController = interfaceController
        self.onSelect = onSelect
        self.onError = onError
    }

    // MARK: - 入口

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let template = CPVoiceControlTemplate(voiceControlStates: [
            makeState(.listening, title: "行き先をどうぞ", symbol: "waveform"),
            makeState(.searching, title: "探しています", symbol: "magnifyingglass"),
        ])

        // **状態を切り替えられるのは、出したあとだけ**（ヘッダの警告）。
        // 先に切り替えても黙って無視されるので、提示の完了を待ってから走らせる。
        interfaceController.presentTemplate(template, animated: true) { [weak self] presented, _ in
            guard let self else { return }
            guard presented else {
                isRunning = false
                return
            }
            run(on: template)
        }
    }

    private func run(on template: CPVoiceControlTemplate) {
        Task {
            defer { isRunning = false }

            do {
                let text = try await SpeechInput.shared.listen(hints: hints)
                template.activateVoiceControlState(withIdentifier: Step.searching.rawValue)

                let intent = await DestinationIntent.parse(text)
                let place = try await resolve(intent.query)

                await dismiss()
                onSelect(intent.kind == .waypoint ? .waypoint(place) : .destination(place))
            } catch {
                // 先に畳む。音声画面を出したままアラートを重ねられない。
                await dismiss()
                onError(error.localizedDescription)
            }
        }
    }

    // MARK: - 検索

    /// 読み解いた語を 1 地点に落とす。
    ///
    /// **運転中に候補を並べない**。読み上げた語にいちばん近いものを取って、そのまま
    /// ルートの提示（＝確認画面）へ渡す。選び直しはそこで「他のルート」ではなく
    /// 案内を始めないことで済む。
    private func resolve(_ query: String) async throws -> Place {
        guard let place = try await search.search(query, near: currentRegion).first else {
            throw Failure.notFound(query)
        }
        return place
    }

    /// 認識に寄せたい語。**固有名詞は一般の言語モデルが落としやすい**ので、
    /// 手元にある地名を渡して拾わせる。多く渡しても効かないため、よく使うものだけ。
    private var hints: [String] {
        Array((store.favorites + store.recents).map(\.name).uniqued.prefix(40))
    }

    private var currentRegion: MKCoordinateRegion? {
        guard let coordinate = location.location?.coordinate else { return nil }
        return MKCoordinateRegion(center: coordinate, latitudinalMeters: 20_000, longitudinalMeters: 20_000)
    }

    // MARK: - 画面

    private func makeState(_ step: Step, title: String, symbol: String) -> CPVoiceControlState {
        CPVoiceControlState(identifier: step.rawValue,
                            titleVariants: [title],
                            image: UIImage(systemName: symbol),
                            repeats: false)
    }

    private func dismiss() async {
        await withCheckedContinuation { continuation in
            interfaceController.dismissTemplate(animated: true) { _, _ in
                continuation.resume()
            }
        }
    }
}

private extension Array where Element: Hashable {
    /// 並び順を保ったまま重複を落とす。お気に入りと履歴には同じ場所が両方入る。
    var uniqued: [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
