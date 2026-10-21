import Combine
import Foundation

/// 音声案内を鳴らすかどうか。iPhone と CarPlay で同じものを見る。
///
/// **消音スイッチの代わりにある。** 案内の声は `.playback` で鳴らしているので
/// （`AudioSessionController`）、iPhone をマナーモードにしても止まらない。
/// `.ambient` にすればスイッチに従うが、そうすると**画面を消している・別のアプリを
/// 前に出しているあいだに声が出せなくなる**（背景で鳴らせるのは `.playback` 系だけ）。
/// CarPlay で走っているときの iPhone はたいていそちらの状態なので、案内そのものが
/// 黙ることになる。スイッチの状態を読む公開 API も無いので、「スイッチを見て
/// 黙る」もできない。Apple のマップも同じ理由でスイッチを無視して読み上げる。
/// そこで、黙らせたい人が確実に黙らせられる入り切りをアプリの側に置く。
///
/// **音量には触らない。** 案内が大きく聞こえるのは、消音スイッチに従う音
/// （着信音量）と `.playback` の音（メディア音量）が別の値だからで、こちらが
/// 上げているわけではない。システムの音量を書き換える API はそもそも無い。
///
/// 案内ロジックではなく声の出し方なので `NavigationController` には置かない。
/// 読むのは `VoiceGuidance` だけ。
@MainActor
final class VoicePreferences: ObservableObject {
    static let shared = VoicePreferences()

    /// 音声案内を消しているか。既定は鳴らす（カーナビの声は、切りで始めると
    /// 案内が始まったことに気づけない）。
    @Published var isMuted: Bool {
        didSet { defaults.set(isMuted, forKey: Self.mutedKey) }
    }

    private let defaults: UserDefaults
    static let mutedKey = "voice.muted"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isMuted = defaults.bool(forKey: Self.mutedKey)
    }

    /// 復元した設定を、両画面が購読している値にも反映する。
    func reload() {
        isMuted = defaults.bool(forKey: Self.mutedKey)
    }
}
