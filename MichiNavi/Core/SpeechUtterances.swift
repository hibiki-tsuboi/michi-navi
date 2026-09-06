import AVFoundation

/// 観光解説を打ち切った後に届く cancel 通知で、次のナビ音声を終了扱いにしない。
struct SpeechUtterances {
    private var active = Set<ObjectIdentifier>()
    private var sightseeing: ObjectIdentifier?

    var isSightseeing: Bool { sightseeing != nil }

    mutating func insert(_ utterance: AVSpeechUtterance, sightseeing: Bool) {
        let id = ObjectIdentifier(utterance)
        active.insert(id)
        if sightseeing { self.sightseeing = id }
    }

    mutating func finish(_ id: ObjectIdentifier) -> Bool {
        guard active.remove(id) != nil else { return false }
        if sightseeing == id { sightseeing = nil }
        return true
    }

    mutating func cancel() {
        active.removeAll()
        sightseeing = nil
    }
}
