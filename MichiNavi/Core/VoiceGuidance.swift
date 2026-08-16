import AVFoundation
import Combine

/// 案内音声の読み上げ。`NavigationController` を購読するだけで、案内ロジックは持たない。
///
/// CarPlay ガイドラインはオーディオセッションの設定値と有効化のタイミングまで指定している。
/// 車の FM ラジオや音楽と共存させるため、読み上げる直前にだけセッションを有効化し、
/// 終わったらすぐ手放す。有効なままにすると音楽がダックされ続け、
/// ポッドキャストは一時停止したままになる。
@MainActor
final class VoiceGuidance: NSObject {
    static let shared = VoiceGuidance()

    private let navigation = NavigationController.shared
    private let session = AVAudioSession.sharedInstance()
    private let synthesizer = AVSpeechSynthesizer()

    private var scheduler: VoicePromptScheduler?
    /// 案内中のルート。これが変わったらリルートとみなす。
    private var currentRouteID: UUID?

    private var isSessionConfigured = false
    /// 音声入力のあいだ読み上げを止めているか。
    private var isSuspended = false
    /// 止めているあいだに届いた 1 回きりの知らせ（到着・経由地通過）。
    private var pendingPrompt: VoicePrompt?
    /// 再生中の音の数。連続で読み上げるときにセッションを切らないための数え上げ。
    private var playingCount = 0
    /// 到着アナウンス中。案内終了で読み上げを打ち切らないために見る。
    private var isAnnouncingArrival = false

    private var tonePlayer: AVAudioPlayer?
    private var cancellables = Set<AnyCancellable>()

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    func start() {
        navigation.$phase
            .sink { [weak self] in self?.apply(phase: $0) }
            .store(in: &cancellables)

        navigation.$progress
            .compactMap { $0 }
            .sink { [weak self] in self?.handle(progress: $0) }
            .store(in: &cancellables)

        navigation.arrived
            .sink { [weak self] route in
                self?.isAnnouncingArrival = true
                self?.speak(.arrival(destination: route.destination.name))
            }
            .store(in: &cancellables)

        // 経由地は案内が続くので、到着と違って読み上げ中に案内が畳まれる心配がない。
        navigation.waypointReached
            .sink { [weak self] in self?.speak(.waypoint(name: $0.name)) }
            .store(in: &cancellables)
    }

    // MARK: - 読み直し

    /// いまの指示をもう一度読む。
    ///
    /// **前に読んだ文をなぞらない**。聞き逃したときに知りたいのは「いまどれだけ手前か」で、
    /// 30 秒前に読んだ「500メートル先」をもう一度言われても役に立たない。
    /// いまの残り距離で作り直す。
    ///
    /// `VoicePromptScheduler` は通さない。あちらは「1 回だけ読む」ための記録を持っており、
    /// 通すと読み直しが済みとして記録されて**本来の予告が消える**。
    func repeatCurrentGuidance() {
        guard case let .navigating(route) = navigation.phase,
              let progress = navigation.progress,
              route.steps.indices.contains(progress.stepIndex) else { return }

        let instruction = route.steps[progress.stepIndex].instruction
        let remaining = progress.distanceToNextManeuver
        speak(.maneuver(instruction: instruction,
                        distance: remaining <= VoicePromptScheduler.imminentThreshold ? nil : remaining))
    }

    // MARK: - 音声入力への譲り

    /// 聞き取りのあいだ読み上げを止める。
    ///
    /// 止める理由は 2 つ。自分の声がマイクへ回り込むこと、そして
    /// **オーディオセッションのカテゴリが `.playAndRecord` に差し替わること**。
    /// `isSessionConfigured` を倒しておくのがここの肝で、こうしないと次の読み上げが
    /// 録音用のカテゴリのまま鳴り、`.measurement` のせいで妙に小さくなる。
    func suspend() {
        isSuspended = true
        stopSpeaking()
        isSessionConfigured = false
    }

    /// 抱えていた出来事があればここで読む。
    func resume() {
        isSuspended = false
        guard let prompt = pendingPrompt else { return }
        pendingPrompt = nil
        speak(prompt)
    }

    // MARK: - 状態の追従

    private func apply(phase: NavigationController.Phase) {
        guard case let .navigating(route) = phase else {
            scheduler = nil
            currentRouteID = nil
            // 到着のひと言だけは最後まで言わせる。
            if !isAnnouncingArrival { stopSpeaking() }
            return
        }

        guard currentRouteID != route.id else { return }
        // 到着を読み上げずに終わった場合（通話中などで promptStyle が none）に
        // フラグが立ったまま次の案内へ持ち越さないよう、ここで必ず倒す。
        isAnnouncingArrival = false
        // 案内中に別ルートへ差し替わった＝リルート。最初のひと言が変わる。
        scheduler = VoicePromptScheduler(isReroute: currentRouteID != nil)
        currentRouteID = route.id
    }

    private func handle(progress: RouteProgress) {
        // **聞き取り中はスケジューラに触らせない。** `prompt(for:on:)` は返した時点で
        // そのしきい値を読み上げ済みとして記録するので、受け取ってから捨てると
        // その予告は二度と出てこない。ここで止めれば、次の位置更新でまた出る。
        guard !isSuspended else { return }

        guard let scheduler,
              let route = navigation.currentRoute,
              let prompt = scheduler.prompt(for: progress, on: route) else { return }
        speak(prompt)
    }

    // MARK: - 読み上げ

    private func speak(_ prompt: VoicePrompt) {
        // 聞き取り中に届くのは到着・経由地通過だけ（予告は `handle(progress:)` で
        // 止めてある）。どちらも**その瞬間しか流れない出来事**なので、落とすと
        // 二度と来ない。抱えておいて、聞き取りが終わってから読む。
        guard !isSuspended else {
            pendingPrompt = prompt
            return
        }

        // 通話中や Siri 使用中は system が鳴らすなと言ってくる。
        // ここで弾けば「鳴らす音が無いのにセッションを有効化しない」という
        // ガイドラインの要求も同時に満たせる。
        switch session.promptStyle {
        case AVAudioSession.PromptStyle.none:
            return
        case .short:
            playTone()
        default:
            speak(text: prompt.spokenText)
        }
    }

    private func speak(text: String) {
        guard activateSession() else { return }
        playingCount += 1

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = preferredVoice
        synthesizer.speak(utterance)
    }

    /// `.short` のときは言葉ではなくトーンで知らせる。
    private func playTone() {
        guard activateSession() else { return }

        do {
            let player = try AVAudioPlayer(data: Self.toneData)
            player.delegate = self
            playingCount += 1
            tonePlayer = player
            player.play()
        } catch {
            NSLog("[MichiNavi] トーンの再生に失敗: \(error.localizedDescription)")
            releaseSessionIfIdle()
        }
    }

    private func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        tonePlayer?.stop()
        tonePlayer = nil
        playingCount = 0
        releaseSessionIfIdle()
    }

    /// 端末の言語で読ませる。MapKit の指示文も端末の言語で返るため表記が揃う。
    private var preferredVoice: AVSpeechSynthesisVoice? {
        let language = Locale.preferredLanguages.first ?? "ja-JP"
        return AVSpeechSynthesisVoice(language: language) ?? AVSpeechSynthesisVoice(language: "ja-JP")
    }

    // MARK: - オーディオセッション

    /// ガイドラインが指定する組み合わせ。カテゴリの設定自体は 1 度でよく、
    /// 読み上げごとに切り替えるのは有効・無効だけ。
    ///
    /// - `interruptSpokenAudioAndMixWithOthers`: ポッドキャストや朗読を一時停止させる
    /// - `duckOthers`: 音楽の音量を下げる
    private func configureSessionIfNeeded() -> Bool {
        if isSessionConfigured { return true }
        do {
            try session.setCategory(.playback,
                                    mode: .voicePrompt,
                                    options: [.interruptSpokenAudioAndMixWithOthers, .duckOthers])
            isSessionConfigured = true
            return true
        } catch {
            NSLog("[MichiNavi] オーディオセッションの設定に失敗: \(error.localizedDescription)")
            return false
        }
    }

    private func activateSession() -> Bool {
        guard configureSessionIfNeeded() else { return false }
        do {
            try session.setActive(true)
            return true
        } catch {
            NSLog("[MichiNavi] オーディオセッションの有効化に失敗: \(error.localizedDescription)")
            return false
        }
    }

    /// 鳴らすものが無くなったら即座に手放す。`notifyOthersOnDeactivation` を付けて
    /// 音楽やポッドキャストをすぐ元に戻す。
    private func releaseSessionIfIdle() {
        guard playingCount == 0, !synthesizer.isSpeaking else { return }
        isAnnouncingArrival = false
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    fileprivate func finishPlaying() {
        playingCount = max(playingCount - 1, 0)
        releaseSessionIfIdle()
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension VoiceGuidance: AVSpeechSynthesizerDelegate {
    // AVSpeechSynthesizer のコールバックはメインスレッドで来る保証が無い。
    // そのため他の delegate のように MainActor.assumeIsolated では受けず、
    // MainActor へ積み直す。
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishPlaying() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishPlaying() }
    }
}

// MARK: - AVAudioPlayerDelegate

extension VoiceGuidance: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.tonePlayer = nil
            self.finishPlaying()
        }
    }
}

// MARK: - トーンの生成

private extension VoiceGuidance {
    /// `.short` のときに鳴らす短いトーン。音声ファイルを同梱せずに済ませるため、
    /// 16bit PCM の WAV をその場で組み立てて使い回す。
    static let toneData: Data = makeToneData()

    static func makeToneData(frequency: Double = 880,
                             duration: Double = 0.15,
                             sampleRate: Double = 44_100) -> Data {
        let frameCount = Int(sampleRate * duration)
        var samples = Data(capacity: frameCount * 2)

        for frame in 0 ..< frameCount {
            // 両端を 10ms かけて出し入れし、プチッというノイズを消す。
            let fadeFrames = sampleRate * 0.01
            let envelope = min(Double(min(frame, frameCount - frame)) / fadeFrames, 1)
            let value = sin(2 * .pi * frequency * Double(frame) / sampleRate) * envelope * 0.3
            samples.append(int16: Int16(max(-1, min(1, value)) * Double(Int16.max)))
        }

        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = UInt32(sampleRate) * UInt32(blockAlign)

        var wav = Data()
        wav.append(ascii: "RIFF")
        wav.append(uint32: UInt32(36 + samples.count))
        wav.append(ascii: "WAVE")
        wav.append(ascii: "fmt ")
        wav.append(uint32: 16)          // fmt チャンクの長さ
        wav.append(uint16: 1)           // 非圧縮 PCM
        wav.append(uint16: channels)
        wav.append(uint32: UInt32(sampleRate))
        wav.append(uint32: byteRate)
        wav.append(uint16: blockAlign)
        wav.append(uint16: bitsPerSample)
        wav.append(ascii: "data")
        wav.append(uint32: UInt32(samples.count))
        wav.append(samples)
        return wav
    }
}

private extension Data {
    mutating func append(ascii text: String) {
        append(contentsOf: Array(text.utf8))
    }

    // Data の拡張内では withUnsafeBytes がインスタンスメソッド側に解決されるため、
    // グローバル関数であることを明示する。
    mutating func append(uint16 value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append(uint32 value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append(int16 value: Int16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
