import AVFoundation
import Combine
import Speech

/// 押して話す目的地入力（iOS 26 の `SpeechAnalyzer`）。
///
/// **走行中はキーボードが塞がれる**（`CPSessionConfiguration.limitedUserInterfaces` に
/// `.keyboard` が入る）ので、これまで新しい目的地を決める手段はお気に入り・履歴・
/// 周辺カテゴリしか無かった。ここはその穴を埋めるためだけにある。
///
/// 責務は「音を文字にする」ところまで。文をどう読むかは `DestinationIntent` が持つ。
///
/// 認可はマイクだけでよい。旧 `SFSpeechRecognizer` は
/// `NSSpeechRecognitionUsageDescription` と `requestAuthorization` を要求するが、
/// **`SpeechAnalyzer` の側には認可 API が無い**（フレームワークのバイナリでも認可の
/// シンボルは `SFSpeechRecognizer` にしか無い）。要らない許可を運転中に求めない。
@MainActor
final class SpeechInput {
    static let shared = SpeechInput()

    enum Failure: LocalizedError {
        case busy
        case microphoneDenied
        case unsupportedLanguage
        case modelUnavailable
        case heardNothing

        var errorDescription: String? {
            switch self {
            case .busy: String(localized: "音声入力がすでに動いています")
            case .microphoneDenied: String(localized: "マイクの使用が許可されていません")
            case .unsupportedLanguage: String(localized: "この言語の音声入力に対応していません")
            case .modelUnavailable: String(localized: "音声認識の準備ができませんでした")
            case .heardNothing: String(localized: "聞き取れませんでした")
            }
        }
    }

    /// 認識の途中経過。CarPlay では出せない（テンプレートの文言が固定なので）が、
    /// iPhone 側に出すときのためと、切り分けのために流している。
    @Published private(set) var partialText = ""

    private let session = AVAudioSession.sharedInstance()
    private var engine: AVAudioEngine?
    private var isListening = false

    /// 最後に音が届いてから、これだけ黙ったら話し終わりとみなす。
    ///
    /// CarPlay の音声画面には**閉じるボタンを置けない**（`CPBarButtonProviding` への
    /// 準拠は iOS 26.4 以降で、`actionButtons` も 26.4）。つまり自動で切り上げるしか
    /// 終わる道が無い。短すぎると住所を言い切る前に切れる。
    private static let silenceTimeout: TimeInterval = 1.4
    /// 話し始めるまで待つ時間。押してから息を吸うぶんがあるので、黙り込みより長く取る。
    private static let leadInTimeout: TimeInterval = 5
    /// 何も起きなくても必ず終わる上限。マイクを開きっぱなしにしない。
    private static let overallTimeout: TimeInterval = 15

    private init() {}

    // MARK: - 聞き取り

    /// 話し終わるまで待って、認識した文を返す。
    ///
    /// - Parameter hints: 認識を寄せたい語（お気に入りや履歴の地名）。
    ///   固有名詞は一般の言語モデルでは落としやすいので、持っているものを渡す。
    func listen(hints: [String] = []) async throws -> String {
        guard !isListening else { throw Failure.busy }
        isListening = true
        partialText = ""

        // **順序が大事**。マイクを閉じてセッションを手放してから読み上げを戻す。
        // 逆にすると、抱えていた到着のひと言が鳴り始めたそばから
        // `teardown` にセッションを落とされて途中で切れる。
        defer {
            isListening = false
            teardown()
            VoiceGuidance.shared.resume()
        }

        guard await AVAudioApplication.requestRecordPermission() else { throw Failure.microphoneDenied }

        let locale = try await Self.supportedLocale()
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        try await Self.prepareModel(for: transcriber, locale: locale)

        // 固有名詞を拾わせる。渡しすぎても効かないので、手前にあるものだけ。
        let context = AnalysisContext()
        context.contextualStrings = [.general: hints]

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Failure.modelUnavailable
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(inputSequence: stream, modules: [transcriber], analysisContext: context)

        // 読み上げを止めるのは**マイクを取る直前**。自分の声が回り込むし、
        // オーディオセッションの持ち主が入れ替わる。初回はこの手前でモデルの取得に
        // 時間がかかることがあり、そこまで黙らせると案内が長く途切れる。
        VoiceGuidance.shared.suspend()
        try activateSession()
        try startEngine(feeding: continuation, to: format)

        let text = try await collect(from: transcriber, analyzer: analyzer, input: continuation)
        guard !text.isEmpty else { throw Failure.heardNothing }
        return text
    }

    /// 結果を集めて、黙ったところで切り上げる。
    private func collect(from transcriber: SpeechTranscriber,
                         analyzer: SpeechAnalyzer,
                         input: AsyncStream<AnalyzerInput>.Continuation) async throws -> String {
        var finalized = ""

        let finish = {
            input.finish()
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        let stopTimer = { (delay: TimeInterval) in
            Task {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await finish()
            }
        }

        // 何も言われなかったときの打ち切り。結果が 1 つでも来たら、
        // 以降は「最後の結果からどれだけ黙ったか」で測り直す。
        var silence = stopTimer(Self.leadInTimeout)
        let deadline = stopTimer(Self.overallTimeout)
        defer { deadline.cancel(); silence.cancel() }

        for try await result in transcriber.results {
            let text = String(result.text.characters)
            if result.isFinal {
                finalized += text
                partialText = finalized
            } else {
                partialText = finalized + text
            }

            silence.cancel()
            silence = stopTimer(Self.silenceTimeout)
        }

        // 途中経過しか来ずに終わった場合（話し終わる前に上限に達したなど）も拾う。
        return finalized.isEmpty ? partialText.trimmed : finalized.trimmed
    }

    // MARK: - モデル

    private static func supportedLocale() async throws -> Locale {
        // 端末の言語を優先し、無ければ日本語。UI 文言が日本語しか無いので落とし先もそこ。
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return match
        }
        guard let japanese = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ja-JP")) else {
            throw Failure.unsupportedLanguage
        }
        return japanese
    }

    /// 認識モデルは端末に入っていないことがある（初回は取得が要る）。
    ///
    /// **`reserve` が先**。予約はただの寿命確保ではなく、そのロケールの購読そのもので、
    /// 予約せずにダウンロードを頼むと
    /// `Cannot check the download status, ... is not subscribed to transcription.ja`
    /// で弾かれる。予約した時点で状態が `installed` に変わることもある
    /// （端末に実体はあって、こちらが繋がっていなかっただけの場合）。
    /// 予約は 5 ロケールまで。
    private static func prepareModel(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        _ = try? await AssetInventory.reserve(locale: locale)
        guard await AssetInventory.status(forModules: [transcriber]) != .installed else { return }

        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                throw Failure.modelUnavailable
            }
            try await request.downloadAndInstall()
        } catch {
            NSLog("[MichiNavi] 認識モデルの用意に失敗: \(error.localizedDescription)")
            throw Failure.modelUnavailable
        }
    }

    // MARK: - マイク

    /// **録音のあいだだけ**カテゴリを差し替える。ふだんは `VoiceGuidance` が
    /// `.playback` を持っているので、戻しはあちらの `resume` に任せる
    /// （次の読み上げでカテゴリを入れ直す）。
    private func activateSession() throws {
        try session.setCategory(.playAndRecord,
                                mode: .measurement,
                                options: [.interruptSpokenAudioAndMixWithOthers, .duckOthers])
        try session.setActive(true)
    }

    private func startEngine(feeding continuation: AsyncStream<AnalyzerInput>.Continuation,
                             to format: AVAudioFormat) throws {
        let engine = AVAudioEngine()
        self.engine = engine

        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        // マイクの形式（多くは 48kHz float）と、認識モデルが受け取る形式は違う。
        // `AVAudioConverter` は音声スレッドの中でしか触らないので、そこへ閉じ込める。
        nonisolated(unsafe) let converter = AVAudioConverter(from: hardware, to: format)

        input.installTap(onBus: 0, bufferSize: 4_096, format: hardware) { buffer, _ in
            guard let converter, let converted = Self.convert(buffer, using: converter, to: format) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }

        engine.prepare()
        try engine.start()
    }

    private func teardown() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        // 音楽やポッドキャストをすぐ元に戻す。
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// マイクの 1 ブロックを認識モデルの形式へ変換する。音声スレッドから呼ばれる。
    private nonisolated static func convert(_ buffer: AVAudioPCMBuffer,
                                            using converter: AVAudioConverter,
                                            to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        // 端数と変換器の内部遅れで溢れないよう、少し多めに確保する。
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var isConsumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            // 1 回のブロックを 1 度だけ渡す。2 度目は「もう無い」と答えないと変換器が待ち続ける。
            if isConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            isConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
