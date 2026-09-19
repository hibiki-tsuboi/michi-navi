import Foundation
import Testing
@testable import MichiNavi

@MainActor
struct AudioSessionControllerTests {
    @Test("起動時の空の解除ではシステムのオーディオセッションに触れない")
    func ignoresIdleDeactivation() async {
        var deactivations = 0
        let controller = AudioSessionController(configure: { _ in }, activate: { true }, deactivate: {
            deactivations += 1
            return true
        })

        _ = await controller.deactivate(for: .guidance).value
        #expect(deactivations == 0)
    }

    @Test("有効化の完了を待って、到着と収穫の再生を予約順に開始する")
    func preservesPlaybackOrder() async {
        let started = Gate()
        let activated = Gate()
        var events: [String] = []
        let controller = AudioSessionController(configure: { _ in events.append("configure") }, activate: {
            events.append("activate")
            started.open()
            await activated.wait()
            return true
        }, deactivate: { true })

        controller.activate(for: .guidance, completion: { if $0 { events.append("arrival") } })
        let second = controller.activate(for: .guidance, completion: { if $0 { events.append("harvest") } })
        await started.wait()
        #expect(events == ["configure", "activate"])

        activated.open()
        #expect(await second.value)
        #expect(events == ["configure", "activate", "arrival", "activate", "harvest"])
    }

    @Test("有効化待ちで中止された音は鳴らさず、完了後にセッションを手放す")
    func cancelsInFlightPlayback() async {
        let started = Gate()
        let activated = Gate()
        let playbackState = PlaybackState()
        var played = false
        var deactivations = 0
        let controller = AudioSessionController(configure: { _ in }, activate: {
            started.open()
            await activated.wait()
            return true
        }, deactivate: {
            deactivations += 1
            return true
        })

        let playback = controller.activate(for: .guidance, isNeeded: { playbackState.needed }) { played = $0 }
        await started.wait()
        playbackState.needed = false
        let release = controller.deactivate(for: .guidance)
        activated.open()

        #expect(await playback.value == false)
        #expect(await release.value)
        #expect(!played)
        #expect(deactivations == 1)
    }

    @Test("有効化に取りかかる前に中止された予約はセッションを取得しない")
    func skipsCancelledReservation() async {
        var activations = 0
        var ready: Bool?
        let controller = AudioSessionController(configure: { _ in }, activate: {
            activations += 1
            return true
        }, deactivate: { true })

        let playback = controller.activate(for: .guidance, isNeeded: { false }) { ready = $0 }
        #expect(await playback.value == false)
        #expect(ready == false)
        #expect(activations == 0)
    }

    @Test("読み上げの解除完了後にマイクへ譲り、遅い解除では録音を切らない")
    func handsOffToMicrophone() async {
        let releasing = Gate()
        let released = Gate()
        var events: [String] = []
        let controller = AudioSessionController(configure: {
            events.append($0 == .guidance ? "playback" : "recording")
        }, activate: {
            events.append("activate")
            return true
        }, deactivate: {
            events.append("deactivate")
            releasing.open()
            await released.wait()
            return true
        })

        _ = await controller.activate(for: .guidance).value
        controller.deactivate(for: .guidance)
        let microphone = controller.activate(for: .recording)
        let staleRelease = controller.deactivate(for: .guidance)
        await releasing.wait()
        #expect(events == ["playback", "activate", "deactivate"])

        released.open()
        #expect(await microphone.value)
        _ = await staleRelease.value
        #expect(events == ["playback", "activate", "deactivate", "recording", "activate"])

        controller.deactivate(for: .recording)
        _ = await controller.activate(for: .guidance).value
        #expect(events.suffix(3) == ["deactivate", "playback", "activate"])
    }

    @Test("有効化が失敗しても後続の再生予約は実行できる", arguments: [true, false])
    func recoversAfterActivationFailure(throwsError: Bool) async {
        var attempts = 0
        var completions: [Bool] = []
        let controller = AudioSessionController(configure: { _ in }, activate: {
            attempts += 1
            if attempts == 1 {
                if throwsError { throw TestFailure.activation }
                return false
            }
            return true
        }, deactivate: { true })

        controller.activate(for: .guidance, completion: { completions.append($0) })
        let retry = controller.activate(for: .guidance, completion: { completions.append($0) })
        #expect(await retry.value)
        #expect(completions == [false, true])
    }

    private enum TestFailure: Error { case activation }

    @MainActor
    private final class PlaybackState {
        var needed = true
    }

    /// 実時間や Task.yield の回数に頼らず、有効化・解除の途中で状態を変えるための門。
    @MainActor
    private final class Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters = []
            for waiter in pending { waiter.resume() }
        }
    }
}
