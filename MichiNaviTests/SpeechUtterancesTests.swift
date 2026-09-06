import AVFoundation
import Testing
@testable import MichiNavi

@MainActor
struct SpeechUtterancesTests {
    @Test("解説を止めた後の遅い完了通知で、次のナビ音声を終了扱いにしない")
    func ignoresCancelledUtteranceAfterNewGuidance() {
        var utterances = SpeechUtterances()
        let story = AVSpeechUtterance(string: "右手に神社があります")
        let turn = AVSpeechUtterance(string: "まもなく右折します")
        utterances.insert(story, sightseeing: true)
        #expect(utterances.isSightseeing)
        utterances.cancel()
        utterances.insert(turn, sightseeing: false)
        #expect(!utterances.isSightseeing)
        let cancelledFinished = utterances.finish(ObjectIdentifier(story))
        let turnFinished = utterances.finish(ObjectIdentifier(turn))
        let duplicateFinished = utterances.finish(ObjectIdentifier(turn))
        #expect(!cancelledFinished)
        #expect(turnFinished)
        #expect(!duplicateFinished)
    }

    @Test("終了した解説を再生中として残さない")
    func completedStoryIsCleared() {
        var utterances = SpeechUtterances()
        let story = AVSpeechUtterance(string: "右手に神社があります")
        utterances.insert(story, sightseeing: true)
        let finished = utterances.finish(ObjectIdentifier(story))
        #expect(finished)
        #expect(!utterances.isSightseeing)
    }
}
