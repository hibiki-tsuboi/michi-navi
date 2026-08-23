import Foundation
import FoundationModels

/// 話した言葉から取り出した「やってほしいこと」。
///
/// 目的地を言うのがいちばん多いが、**走行中に押せるボタンの数は物理的に限られる**ので、
/// 声の側を厚くするほうが理にかなっている。読み直しや案内終了はボタンも残してあるが、
/// 手を伸ばさずに済むならそのほうがよい。
enum VoiceCommand: Equatable {
    /// 行き先を決める。`asWaypoint` なら、いまの経路に挟む。
    case destination(query: String, asWaypoint: Bool)
    /// 案内をやめる。
    case endNavigation
    /// いまの指示をもう一度読む。
    case repeatGuidance
    /// 経路全体を表示する。
    case overview
    /// 自宅へ帰る。
    ///
    /// **検索を通さない**のがこの case の理由。「自宅」と言われて `.destination` に
    /// 落とすと、`自宅` という語で地図を探しに行って別の場所が当たる。ピン留めした
    /// 座標が手元にあるのだから、そこへ直に渡す。**帰り道は走行中に決まる**ことが多く、
    /// そのとき使える入口はマイクだけなので、ここを外すと届く道が無い。
    case goHome
}

/// 言語モデルに埋めさせる形。`@Generable` を付けた型は、返答が必ずこの形に収まる。
@Generable
private struct SpokenRequest {
    @Guide(description: "やってほしいことの種類。destination（行き先を決める）、waypoint（途中に立ち寄る）、end（案内をやめる）、repeat（もう一度案内を読む）、overview（全体を表示）、home（自宅へ帰る）のいずれか。")
    var action: String

    @Guide(description: "行き先や立ち寄り先の検索語。地名・施設名・カテゴリ名だけを残し、「〜に行きたい」「〜に寄って」のような言い回しは落とす。行き先の指定でなければ空文字。")
    var query: String
}

extension VoiceCommand {
    /// 話した文を読み解く。
    ///
    /// **言語モデルが使えなくても止めない。** Apple Intelligence は対応機種かつ利用者が
    /// 有効にしている場合しか動かないので、そのときは決まった言い回しの拾い出しに落ちる
    /// （`fallback`）。効きは落ちるが、口で言えること自体は保たれる。
    static func parse(_ text: String, isNavigating: Bool) async -> VoiceCommand {
        guard SystemLanguageModel.default.isAvailable else {
            return fallback(from: text, isNavigating: isNavigating)
        }

        do {
            let session = LanguageModelSession {
                """
                あなたはカーナビの入力を整える係です。運転者が話した言葉から、
                やってほしいことと、地図の検索に渡す語を取り出してください。
                説明や言い換えを足さず、話に出てきた語だけを使ってください。
                """
            }
            let answer = try await session.respond(to: text, generating: SpokenRequest.self)
            let query = answer.content.query.trimmed

            switch answer.content.action.lowercased() {
            case "end": return .endNavigation
            case "repeat": return .repeatGuidance
            case "overview": return .overview
            case "home": return .goHome
            case "waypoint" where !query.isEmpty: return .destination(query: query, asWaypoint: isNavigating)
            default:
                // 行き先のつもりなのに検索語が空なら、読み解きが外れている。
                // 話した文をそのまま渡したほうがまだ当たる。
                return .destination(query: query.isEmpty ? text.trimmedForSearch : query, asWaypoint: false)
            }
        } catch {
            NSLog("[MichiNavi] 音声入力の読み解きに失敗: \(error.localizedDescription)")
            return fallback(from: text, isNavigating: isNavigating)
        }
    }

    /// 言語モデルを通さない読み解き。
    ///
    /// 決まった言い回しだけを拾い、当てはまらなければ行き先として扱う。**取りこぼしても
    /// 検索に落ちるだけ**なので、無理に拾おうとして誤爆させるより漏らすほうがよい。
    /// 「終わり」だけで案内を切ると、同乗者との会話でも切れてしまう。
    static func fallback(from text: String, isNavigating: Bool) -> VoiceCommand {
        let normalized = text.trimmed

        // **日英どちらの言い回しも同じ表に置く**（`ManeuverDirection` と同じ形）。
        // 認識は端末の言語で動くので、どちらが来るかはここでは決まらない。
        if normalized.containsAny(of: ["案内をやめ", "案内を終了", "案内終了", "ナビを終了", "案内をストップ",
                                       "stop navigation", "end navigation", "cancel navigation",
                                       "stop the route", "stop guidance"]) {
            return .endNavigation
        }
        if normalized.containsAny(of: ["もう一度", "もういちど", "もう1回", "もう一回", "聞き逃",
                                       "say that again", "repeat that", "repeat the"]) {
            return .repeatGuidance
        }
        if normalized.containsAny(of: ["全体を表示", "全体表示", "ルート全体",
                                       "show the whole route", "show the route", "route overview"]) {
            return .overview
        }
        // **「帰る」だけでは拾わない。** 同乗者との会話で誤爆する（「そろそろ帰るね」）。
        // いっぽう「自宅」は単独でも拾う。地図でその語を探しても何も当たらないので、
        // 検索へ落とすより帰り道と読むほうが必ず当たりが良い。
        if normalized.containsAny(of: ["自宅", "家に帰", "家へ帰", "うちに帰", "帰宅",
                                       "go home", "take me home", "navigate home", "drive home",
                                       "head home", "route home"]) {
            return .goHome
        }

        let asWaypoint = isNavigating
            && normalized.containsAny(of: ["途中で", "ついでに", "寄って", "寄りたい", "立ち寄",
                                           "stop by", "stop at", "on the way", "along the way"])
        return .destination(query: normalized.trimmedForSearch, asWaypoint: asWaypoint)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 検索語にするときだけ末尾の句読点を落とす。
    ///
    /// 認識結果には「〜に寄って。」のように句点が付いてくることがあり、検索語に
    /// 混ぜても何の役にも立たない。言い回しそのものを削るのは言語モデルの仕事で、
    /// ここで語尾を並べて削り始めると当たり外れが大きくなる。
    var trimmedForSearch: String {
        let stripped = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "。、．，.,!?！？"))
        return stripped.isEmpty ? trimmed : stripped
    }

    func containsAny(of needles: [String]) -> Bool {
        needles.contains { localizedCaseInsensitiveContains($0) }
    }
}
