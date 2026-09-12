import Testing
@testable import MichiNavi

@MainActor
struct HighwaySectionsTests {
    /// 入口から出口までのあいだだけ高速として扱う。**名乗らない指示を挟んでも引き継ぐ**
    /// ——ここで戻すと、同じ道を走っているのにカードの色が点滅する。
    @Test("入口から出口までを高速として引き継ぐ")
    func rampToRamp() {
        let sections = HighwaySections.map(of: [
            "",
            "神田橋ランプで左方向 首都高速都心環状線入口へ",
            "竹橋JCTで左車線を走行して首都高速3号線（渋谷、東名方面）へ",
            "そのまま直進します",
            "渋谷ランプで出口",
            "交差点を右折します",
        ])
        #expect(sections == [false, false, true, true, true, false])
    }

    /// 出発地の道を教えてくれる指示文が無いので、最初の step は根拠を持たない。
    @Test("最初の step は高速と言い切らない")
    func firstStepHasNoEvidence() {
        let sections = HighwaySections.map(of: ["首都高速都心環状線を進みます", "そのまま直進します"])
        #expect(sections == [false, true])
    }

    /// 高速＝緑は日本の案内標識の決まりで、国によって逆になる。英語の指示文では青のまま。
    @Test("英語の指示文では高速にしない")
    func englishStaysOffHighway() {
        let sections = HighwaySections.map(of: [
            "",
            "Take the ramp on the right to the Tomei Expressway",
            "Continue on the freeway",
            "Keep left at the interchange",
        ])
        #expect(sections == [false, false, false, false])
    }

    /// 降りる側は言語を問わず効かせる。間違えるなら一般道を緑にしないほうへ倒す。
    @Test("出口は英語でも一般道へ戻す")
    func englishExitStillLeaves() {
        let sections = HighwaySections.map(of: [
            "",
            "首都高速3号渋谷線（渋谷、東名方面）へ",
            "Take exit 23B on the left",
            "交差点を右折します",
        ])
        #expect(sections == [false, false, true, false])
    }

    /// ランプ名・JCT名は入口の操作と一緒でなければ本線に乗った証拠にならない。
    /// 国道や県道も、番号だけでは高速と区別できない。
    @Test("ランプ名や一般道の指示では高速にしない")
    func namesAloneAreNotEnough() {
        let sections = HighwaySections.map(of: [
            "",
            "渋谷ランプで右方向",
            "国道246号を直進します",
            "交差点を左折します",
        ])
        #expect(sections == [false, false, false, false])
    }
}
