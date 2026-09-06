import Foundation

/// 指示文から「どう曲がるか」を推測する。
///
/// MapKit の `MKRoute.Step` は「右折します」のような文言しか返さず、曲がる向きを表す
/// 列挙型が公開されていない。そのため文言から推測するしかない。
///
/// **この推測を CarPlay の型から切り離してある**のは、向きを使うのが表示だけでは
/// ないため。候補ルートの右折の数を数える（`RouteCharacter`）のは案内の見た目とは
/// 無関係な計算で、そちらのために CarPlay を `Core/` へ持ち込みたくない。
/// 見た目への読み替えは `ManeuverKind` が持つ。
///
/// 経路プロバイダを Mapbox などに差し替えると構造化された maneuver type が
/// 得られるので、そのときはこのファイルごと不要になる。
enum ManeuverDirection {
    enum Side { case left, right }

    case uTurn
    case roundabout
    case offRamp
    case onRamp
    case merge
    /// 車線・分岐を選ぶ指示。交差点での右左折とは区別する。
    case keepRight
    case keepLeft
    case slightRight
    case slightLeft
    case right
    case left
    case arrive
    case depart
    case straight
    /// どの規則にも当てはまらなかった。
    case unknown

    /// 判定は上から順に行う。規則は 2 つある。
    ///
    /// 1. **長い語を短い語より先に置く。** 「斜め右」は「右」より先、「ロータリー」は
    ///    「出口」より先でなければならない。後者を逆にすると「2 番目の出口で出る」が
    ///    高速の出口として扱われる。
    /// 2. **道路名に現れる語を入れない。** 「環状」を入れていたときは「環状1号を右方向」が
    ///    ロータリー扱いになり、アイコンだけでなく `CPManeuver.maneuverType` として
    ///    `.enterRoundabout` が車のメーター・HUD へ送られていた（2026-08-16 に横浜で実測）。
    ///    日本の道路名には「環状八号線」「内環状」のように普通に入る。**取りこぼすほうが
    ///    まだ良い**（`VoiceCommand` の fallback と同じ判断）ので、交差点だと分かる形に絞る。
    private static let rules: [(keywords: [String], direction: ManeuverDirection)] = [
        (["Uターン", "U ターン", "u-turn", "U-turn"], .uTurn),
        (["ロータリー", "環状交差点", "roundabout", "rotary"], .roundabout),
    ]

    private static let movementRules: [(keywords: [String], direction: ManeuverDirection)] = [
        (["合流", "merge"], .merge),
        // **車線の指示は曲がる指示より先。** 「右車線を走行して環八通りへ」を右折と
        // 読むと、分岐の手前でハンドルを切らせることになる。ただし高速の入口・出口より
        // 後ろに置く（「池尻ランプで右車線を走行 首都高速入口へ」は入口が主）。
        (["右車線", "右の車線", "右側の車線", "keep right", "right lane", "right lanes"], .keepRight),
        (["左車線", "左の車線", "左側の車線", "keep left", "left lane", "left lanes"], .keepLeft),
        (["斜め右", "右斜め", "slight right", "bear right"], .slightRight),
        (["斜め左", "左斜め", "slight left", "bear left"], .slightLeft),
        (["右方向", "右折", "右に", "右へ", "turn right"], .right),
        (["左方向", "左折", "左に", "左へ", "turn left"], .left),
        // 「駐車を準備」は MapKit が車を降ろす地点に置く指示で、徒歩の step を落として
        // いる（`MKRoute.drivingSteps`）いま、**これが経路の最後の指示になる**。
        (["到着", "目的地", "駐車", "arrive", "destination", "park"], .arrive),
        (["出発", "depart"], .depart),
        (["直進", "そのまま", "continue", "straight", "head"], .straight),
    ]

    static func inferred(from instruction: String) -> ManeuverDirection {
        let action = actionText(in: instruction)
        if let special = matchedDirection(in: action, rules: rules) { return special }

        // 「生麦出口方面」は降りる指示ではない。括弧内の方面を除き、出口の動作だけを読む。
        if matches(#"出口(?=$|\s|へ|を|に|で|から)|降り|\b(?:off[ -]ramp|exit)\b"#, in: action) {
            return .offRamp
        }
        // 道路名に「高速」があるだけでは入口にしない。ICで国道の有料区間へ入る場合もある。
        let entersRoad = matches(#"入口(?:へ|に|$)|(?:に|へ)(?:入|乗)"#, in: action)
        if (hasHighwayContext(in: action) && entersRoad)
            || matches(#"\bon[ -]ramp\b|\btake (?:the )?(?:(?:left|right) )?ramp\b|\benter (?:the )?(?:highway|freeway|expressway|motorway)\b"#, in: action) {
            return .onRamp
        }
        let movement = matchedDirection(in: action, rules: movementRules) ?? .unknown
        // JCTや明示された分岐の「右方向」を、90度曲がる右折の矢印にしない。
        if matches(#"JCT(?![a-z])|ジャンクション|分岐|\bfork\b"#, in: action),
           [.right, .left, .slightRight, .slightLeft, .unknown].contains(movement),
           let side = side(in: action) {
            return side == .left ? .keepLeft : .keepRight
        }
        return movement
    }

    /// 左右が明記された場合だけ返す。経路のカーブや日本の左側通行から出口の側を推測しない。
    /// 両方の側が書かれた複合指示も、一方を選ぶ根拠がないので nil にする。
    static func side(in instruction: String) -> Side? {
        let action = actionText(in: instruction)
        let left = matches(#"左(?:車線|側|方向|斜め|へ|に|折|の車線)|斜め左|分岐(?:で|を)左|\b(?:keep|bear|turn|slight) left\b|\bleft(?:-hand)?[ -](?:exit|ramp|lanes?)\b|\bon (?:the )?left\b"#, in: action)
        let right = matches(#"右(?:車線|側|方向|斜め|へ|に|折|の車線)|斜め右|分岐(?:で|を)右|\b(?:keep|bear|turn|slight) right\b|\bright(?:-hand)?[ -](?:exit|ramp|lanes?)\b|\bon (?:the )?right\b"#, in: action)
        guard left != right else { return nil }
        return left ? .left : .right
    }

    static func hasHighwayContext(in instruction: String) -> Bool {
        matches(#"高速|自動車道|有料道路|ランプ|ジャンクション|インターチェンジ|(?<![a-z])(?:JCT|IC)(?![a-z])|\b(?:highway|freeway|expressway|motorway|interchange|ramp)\b"#, in: instruction)
    }

    /// 入口と分岐を区別しても、高速上から始まる経路を「下道のみ」に変えないため。
    static func usesHighway(in instruction: String) -> Bool {
        let direction = inferred(from: instruction)
        if direction == .onRamp { return true }
        let action = actionText(in: instruction, excludingRoadName: false)
        // 「2番目の出口」だけでは高速かどうか分からない。名前付きのIC・ランプなどで確認する。
        if direction == .offRamp { return hasHighwayContext(in: action) }
        guard [.straight, .keepLeft, .keepRight, .merge].contains(direction) else { return false }
        return matches(#"高速|自動車道|有料道路|\b(?:highway|freeway|expressway|motorway)\b"#,
                       in: action)
    }

    /// 方面・標識の名前に含まれる「出口」「右」などを、操作の指示と取り違えないため。
    private static func actionText(in instruction: String, excludingRoadName: Bool = true) -> String {
        let action = instruction.replacingOccurrences(of: #"（[^（）]*）|\([^()]*\)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b(?:towards?|follow signs for)\b.*$"#, with: "",
                                  options: [.regularExpression, .caseInsensitive])
        guard excludingRoadName else { return action }
        return action.replacingOccurrences(of: #"\bonto\b.*$|\bon\s+(?!the (?:left|right)\b).*$"#, with: "",
                                           options: [.regularExpression, .caseInsensitive])
    }

    private static func matches(_ pattern: String, in instruction: String) -> Bool {
        instruction.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func matchedDirection(in instruction: String,
                                         rules: [(keywords: [String], direction: ManeuverDirection)]) -> ManeuverDirection? {
        rules.first { rule in
            rule.keywords.contains { keyword in
                // 英語の部分一致で「Wright」「Parkway」を右折・到着にしない。
                if keyword.unicodeScalars.allSatisfy(\.isASCII) {
                    return matches("\\b" + NSRegularExpression.escapedPattern(for: keyword) + "\\b", in: instruction)
                }
                return instruction.localizedCaseInsensitiveContains(keyword)
            }
        }?.direction
    }

    /// 一言で言い切った指示。**狭い画面のための短縮形**。
    ///
    /// MapKit の指示文は「市役所前で左方向 百万石通り」のように地名と道路名を抱えていて、
    /// Dashboard や通知バナーの幅には入らない。CarPlay は渡した候補の先頭から**入るものを
    /// 選ぶ**ので、長い文が入らないときの落とし先を用意しておく。
    /// ただし高速・車線・方面の指示では地名を落とせないので、`ManeuverInstruction` が使い分ける。
    ///
    /// **上の `rules` と役割が逆なので混同しないこと。** あちらは MapKit から来る文を
    /// 読むための表なので訳さず日英を並べる。こちらは利用者に見せる文なので、
    /// 端末の言語に訳す。
    var shortInstruction: String? {
        switch self {
        case .uTurn: String(localized: "Uターン")
        case .roundabout: String(localized: "ロータリー")
        case .offRamp: String(localized: "出口")
        case .onRamp: String(localized: "入口")
        case .merge: String(localized: "合流")
        case .keepRight: String(localized: "右車線")
        case .keepLeft: String(localized: "左車線")
        case .slightRight: String(localized: "斜め右")
        case .slightLeft: String(localized: "斜め左")
        case .right: String(localized: "右折")
        case .left: String(localized: "左折")
        case .arrive: String(localized: "到着")
        case .depart: String(localized: "出発")
        case .straight: String(localized: "直進")
        // 向きが分からないものを縮めても、意味の無い言葉しか作れない。
        // 渡さなければ CarPlay が元の指示文へ落ちる。
        case .unknown: nil
        }
    }

    /// 交差点で右へ向く指示か。日本のような左側通行では、これが多いほど
    /// 対向車を待つ場面が増える。
    var isRightTurn: Bool { self == .right || self == .slightRight }
}
