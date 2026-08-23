import Foundation
import Testing

@testable import MichiNavi

/// 背景測位の前提。
///
/// `LocationService.setNavigating` は案内中に `allowsBackgroundLocationUpdates` を立てる。
/// **あれが要求するのは Info.plist の背景モードだけ**で、認可が「常に許可」かどうかは
/// 見ていない（26.6 で `.authorizedWhenInUse` のまま立てられることを実測）。
///
/// 裏を返すと、**背景モードを外した瞬間に例外になる**。しかも落ちるのは案内を始めた
/// ときなので、**気づくのは走り出してから**。ここで止める。
@MainActor
struct BackgroundModeTests {
    /// テストはアプリのプロセスで動く（`TEST_HOST`）ので、`Bundle.main` はアプリのもの。
    private var backgroundModes: [String] {
        Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
    }

    @Test("位置情報の背景モードが宣言されている")
    func declaresLocationBackgroundMode() {
        #expect(backgroundModes.contains("location"))
    }

    /// 読み上げは案内中に鳴る。こちらも外すと走行中にしか症状が出ない。
    @Test("音声の背景モードが宣言されている")
    func declaresAudioBackgroundMode() {
        #expect(backgroundModes.contains("audio"))
    }
}
