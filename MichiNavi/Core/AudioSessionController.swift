import AVFoundation

/// 読み上げとマイクが共有するセッション。非同期の有効化・解除を呼び出し順に完了させる。
@MainActor
final class AudioSessionController {
    static let shared = AudioSessionController()

    nonisolated enum Usage: Sendable {
        case guidance
        case recording
    }

    private let configure: @MainActor (Usage) async throws -> Void
    private let activateSession: @MainActor () async throws -> Bool
    private let deactivateSession: @MainActor () async throws -> Bool
    private var configuredUsage: Usage?
    private var activeUsage: Usage?
    private var pendingOperation: Task<Bool, Never>?

    init(configure: @escaping @MainActor (Usage) async throws -> Void = {
             try await AudioSessionController.configure(for: $0)
         },
         activate: @escaping @MainActor () async throws -> Bool = { try await AudioSessionController.activate() },
         deactivate: @escaping @MainActor () async throws -> Bool = { try await AudioSessionController.deactivate() }) {
        self.configure = configure
        activateSession = activate
        deactivateSession = deactivate
    }

    /// 予約は同期で行い、待ち時間だけを非同期にする。完了通知も次の操作より先に届ける。
    /// `isNeeded` は待っている間に案内が中止された場合、古い音を鳴らさないための判定。
    @discardableResult
    func activate(for usage: Usage,
                  isNeeded: @escaping @MainActor () -> Bool = { true },
                  completion: @escaping @MainActor (Bool) -> Void = { _ in }) -> Task<Bool, Never> {
        enqueue {
            guard isNeeded() else {
                completion(false)
                return false
            }
            do {
                if self.configuredUsage != usage {
                    try await self.configure(usage)
                    self.configuredUsage = usage
                }
                let activated = try await self.activateSession()
                if activated { self.activeUsage = usage }
                let ready = activated && isNeeded()
                completion(ready)
                return ready
            } catch {
                NSLog("[MichiNavi] オーディオセッションの有効化に失敗: \(error.localizedDescription)")
                completion(false)
                return false
            }
        }
    }

    /// 別の用途へ譲った後の遅い解除通知で、マイクや次の読み上げを切らない。
    @discardableResult
    func deactivate(for usage: Usage) -> Task<Bool, Never> {
        enqueue {
            guard self.activeUsage == usage else { return true }
            do {
                let deactivated = try await self.deactivateSession()
                if deactivated { self.activeUsage = nil }
                return deactivated
            } catch {
                NSLog("[MichiNavi] オーディオセッションの解除に失敗: \(error.localizedDescription)")
                return false
            }
        }
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Bool) -> Task<Bool, Never> {
        let previous = pendingOperation
        let task = Task {
            _ = await previous?.value
            return await operation()
        }
        pendingOperation = task
        return task
    }

    // カテゴリ変更もハードウェアとの同期を伴うので、MainActor の外で実行する。
    private nonisolated static func configure(for usage: Usage) async throws {
        try await Task.detached {
            try AVAudioSession.sharedInstance().setCategory(
                usage == .guidance ? .playback : .playAndRecord,
                mode: usage == .guidance ? .voicePrompt : .measurement,
                options: [.interruptSpokenAudioAndMixWithOthers, .duckOthers])
        }.value
    }

    private nonisolated static func activate() async throws -> Bool {
        let session = AVAudioSession.sharedInstance()
        if #available(iOS 27.0, *) {
            return try await session.activate(options: [])
        }
        // 26 系には非同期 API がない。専用の仕事へ渡して UI を待たせない。
        return try await Task.detached {
            try session.setActive(true)
            return true
        }.value
    }

    private nonisolated static func deactivate() async throws -> Bool {
        let session = AVAudioSession.sharedInstance()
        if #available(iOS 27.0, *) {
            return try await session.deactivate(options: .notifyOthersOnDeactivation)
        }
        return try await Task.detached {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            return true
        }.value
    }
}
