import Foundation
import FoundationModels

/// 話した文から「何を探すか」を取り出す。
///
/// 「東京駅」とだけ言う人はまずいない。「東京駅に行きたい」「途中でガソリン入れたい」の
/// ように言うので、そのまま `MKLocalSearch` に渡すと外す。オンデバイスの言語モデルで
/// 検索語と扱い（目的地か立ち寄り先か）に分けてから渡す。
///
/// **モデルが使えなくても機能を止めない。** Apple Intelligence は対応機種かつ利用者が
/// 有効にしている場合しか動かない。使えないときは話した文をそのまま検索語にする
/// （`fallback`）。効きは落ちるが、目的地を口で言えること自体は保たれる。
struct DestinationIntent: Equatable {
    /// `MKLocalSearch` に渡す検索語。
    let query: String
    /// 目的地にするか、いまの案内に挟むか。
    let kind: Kind

    enum Kind: String, Equatable {
        case destination
        case waypoint
    }

    /// 言語モデルを通さずに組み立てる。話した文をほぼそのまま検索語にする。
    ///
    /// 落とすのは末尾の句読点だけ。認識結果には「〜に寄って。」のように句点が付いてくる
    /// ことがあり、検索語に混ぜても何の役にも立たない。言い回しそのものを削るのは
    /// 言語モデルの仕事で、ここで語尾を並べて削り始めると当たり外れが大きくなる。
    static func fallback(from text: String) -> DestinationIntent {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "。、．，.,!?！？"))
        return DestinationIntent(query: trimmed.isEmpty ? text : trimmed, kind: .destination)
    }
}

/// 言語モデルに埋めさせる形。`@Generable` を付けた型は、返答が必ずこの形に収まる。
@Generable
private struct SpokenDestination {
    @Guide(description: "地図の検索にそのまま渡せる語。地名・施設名・カテゴリ名だけを残し、「〜に行きたい」「〜に寄って」のような言い回しは落とす。")
    var query: String

    @Guide(description: "目的地そのものなら destination、いまの案内の途中に立ち寄るなら waypoint。「途中で」「ついでに」「寄って」と言っていれば waypoint。")
    var kind: String
}

extension DestinationIntent {
    /// 話した文を読み解く。読み解けなければ `fallback` に落ちる。
    ///
    /// 運転中に待たせる時間なので、失敗を投げずに必ず何かを返す。
    static func parse(_ text: String) async -> DestinationIntent {
        guard SystemLanguageModel.default.isAvailable else { return .fallback(from: text) }

        do {
            let session = LanguageModelSession {
                """
                あなたはカーナビの入力を整える係です。運転者が話した言葉から、
                地図の検索に渡す語と、その扱いを取り出してください。
                説明や言い換えを足さず、話に出てきた語だけを使ってください。
                """
            }
            let answer = try await session.respond(to: text, generating: SpokenDestination.self)
            let query = answer.content.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return .fallback(from: text) }

            return DestinationIntent(query: query,
                                     kind: Kind(rawValue: answer.content.kind) ?? .destination)
        } catch {
            // 使えない・断られた・時間切れ、どれでも入力そのものは残っている。
            NSLog("[MichiNavi] 音声入力の読み解きに失敗: \(error.localizedDescription)")
            return .fallback(from: text)
        }
    }
}
