import Foundation

/// その step を走っているあいだ、高速道路の上にいるか。
///
/// 案内カードの色を日本の案内標識に合わせるために使う（高速＝緑、一般道＝青）。
/// **MapKit は道路種別を返さない**ので、指示文から読むしかない。
///
/// - **見るのはひとつ前の step の指示文。** `steps[i].instruction` は step i の *終わり* で
///   行う操作なので、step i を走っているあいだに乗っている道は**ひとつ前の操作で入った道**
///   （`CarPlayCoordinator.roadNames` が道路名を 1 つずらして並べるのと同じ理屈）。
///   次の指示が「渋谷ランプで出口」でも、それが出ているあいだはまだ高速の上にいる。
/// - **入口と出口で状態が変わるので、頭から辿って引き継ぐ。** 高速の途中の指示は
///   「○○JCTで左車線を走行」のように道路名を名乗らないことがあり、そこで戻すと
///   **同じ道を走っているのに色が点滅する**。
/// - **最初の step は必ず false。** 出発地の道を教えてくれる指示文が無く、
///   `MKRoute.name` は経路全体の代表名なので根拠にならない（`currentRoadNameVariants` を
///   最初の step だけ空にしているのと同じ穴）。
/// - **緑にする側は日本語の語だけで判定する。** `ManeuverDirection` の表と違い、
///   **日英を並べない**。高速＝緑・一般道＝青は**日本の案内標識の決まり**で、国によって
///   逆になる（フランスは autoroute が青、route nationale が緑）。日本の標識だけを描く
///   `RoadShieldImage` と同じ扱い。**青へ戻す側（出口）は言語を問わない**——
///   間違えたときに一般道を緑にしないほうが安全なため。
enum HighwaySections {
    /// 各 step を走っているあいだ高速の上にいるか、を経路 1 本ぶん並べる。
    static func map(of instructions: [String]) -> [Bool] {
        var onHighway = false
        return instructions.indices.map { index in
            guard index > 0 else { return false }
            onHighway = state(after: instructions[index - 1], previously: onHighway)
            return onHighway
        }
    }

    private static func state(after instruction: String, previously onHighway: Bool) -> Bool {
        let direction = ManeuverDirection.inferred(from: instruction)
        // 降りたら一般道。ここだけは英語の指示文でも効かせる。
        if direction == .offRamp { return false }
        // 「高速」が道路名にあるだけでは入口にならない（`ManeuverDirection` の判定）ので、
        // 入口の操作と、進む道路そのものが高速と名乗っている場合の両方を見る。
        if direction == .onRamp, matches(context, in: instruction) { return true }
        return matches(names, in: instruction) ? true : onHighway
    }

    /// 高速の入口を名乗る語。`ManeuverDirection.hasHighwayContext` の日本語のぶんだけ。
    private static let context = #"高速|自動車道|有料道路|ランプ|ジャンクション|インターチェンジ|(?<![a-z])(?:JCT|IC)(?![a-z])"#
    /// 進んだ先が高速そのものだと分かる語。ランプ名やJCT名だけでは本線に乗ったと言えない。
    private static let names = #"高速|自動車道|有料道路"#

    private static func matches(_ pattern: String, in instruction: String) -> Bool {
        instruction.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
