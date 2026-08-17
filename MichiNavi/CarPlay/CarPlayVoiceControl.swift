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
            case let .notFound(query): String(localized: "「\(query)」は見つかりませんでした")
            }
        }
    }

    private let interfaceController: CPInterfaceController
    private let onSelect: (CarPlayDestinationBrowser.Choice) -> Void
    private let onCommand: (VoiceCommand) -> Void
    private let onError: (String) -> Void

    private let search = SearchService.shared
    private let store = DestinationStore.shared
    private let location = LocationService.shared

    /// 二重に走らせない。ボタンの連打と、CarPlay 側の再入の両方を止める。
    private var isRunning = false

    /// 聞き取りから検索までの一続き。**閉じるボタンから取り消すために持つ。**
    private var task: Task<Void, Never>?

    init(interfaceController: CPInterfaceController,
         onSelect: @escaping (CarPlayDestinationBrowser.Choice) -> Void,
         onCommand: @escaping (VoiceCommand) -> Void,
         onError: @escaping (String) -> Void) {
        self.interfaceController = interfaceController
        self.onSelect = onSelect
        self.onCommand = onCommand
        self.onError = onError
    }

    // MARK: - 入口

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let template = CPVoiceControlTemplate(voiceControlStates: [
            makeState(.listening, title: String(localized: "行き先をどうぞ"), symbol: "waveform"),
            makeState(.searching, title: String(localized: "探しています"), symbol: "magnifyingglass"),
        ])
        // **iOS 26.4 から、この画面にもボタンを置ける。** それ以前は閉じる手がひとつも
        // 無く、黙って自動で切り上がる（無音 1.4 秒／上限 15 秒）のを待つほかなかった。
        // **自動で切り上げる仕組みは残す。** 26.0〜26.3 ではそれが唯一の出口だし、
        // 26.4 以降でも話し終わりを押させるためのボタンではない。
        //
        // 置き場所は**ナビゲーションバー**。`actionButtons` は名前が近いが
        // `CPVoiceControlState`（状態ごとの操作）のもので、画面そのものを畳む役ではない。
        // なお `CPBarButtonProviding` 準拠のほうは **`__IPHONE_OS_VERSION_MIN_REQUIRED`
        // で切られている**（＝下限が 26.0 のうちは protocol として見えない）が、
        // プロパティ自体はクラスに生えているので `#available` で足りる。
        if #available(iOS 26.4, *) {
            template.trailingNavigationBarButtons = [closeButton]
        }

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

    /// **取り消されたら、そこから先は何もしない。** 画面は `cancel()` が畳み終えているので
    /// `dismiss()` も呼ばず、聞き取った語も捨てる。閉じたのに案内が始まるのがいちばん困る。
    private func run(on template: CPVoiceControlTemplate) {
        task = Task {
            defer { isRunning = false }

            do {
                let text = try await SpeechInput.shared.listen(hints: hints)
                guard !Task.isCancelled else { return }
                template.activateVoiceControlState(withIdentifier: Step.searching.rawValue)

                let command = await VoiceCommand.parse(text, isNavigating: NavigationController.shared.currentRoute != nil)
                guard !Task.isCancelled else { return }

                // 行き先だけは検索が要るので、画面を出したまま探す。
                // それ以外は待たせる意味が無いので、先に畳んでから実行する。
                guard case let .destination(query, asWaypoint) = command else {
                    await dismiss()
                    onCommand(command)
                    return
                }

                let place = try await resolve(query)
                guard !Task.isCancelled else { return }
                await dismiss()
                onSelect(asWaypoint ? .waypoint(place) : .destination(place))
            } catch {
                guard !Task.isCancelled else { return }
                // 先に畳む。音声画面を出したままアラートを重ねられない。
                await dismiss()
                onError(error.localizedDescription)
            }
        }
    }

    /// 閉じるボタン（iOS 26.4 以降）。**押した時点で画面を畳む。**
    ///
    /// マイクを閉じるのは `SpeechInput` に任せる。あちらはオーディオセッションの
    /// 受け渡し（読み上げを止める・戻す）を決まった順序で畳む作りになっていて、
    /// 途中から手を出すとその順序を壊す。取り消しを受けて自分で戻るので、待てばよい。
    /// **そのぶん、閉じた直後にもう一度マイクを押しても反応しないことがある**
    /// （`isRunning` が下りるのは畳み終わったとき）。
    private func cancel() {
        task?.cancel()
        task = nil
        Task { await dismiss() }
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

    /// 題で置く。**絵にしない。** 地図側の「完了」「案内終了」と同じ形にしておけば、
    /// 押す前に何が起きるか読める。
    @available(iOS 26.4, *)
    private var closeButton: CPBarButton {
        CPBarButton(title: String(localized: "閉じる")) { [weak self] _ in self?.cancel() }
    }

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
