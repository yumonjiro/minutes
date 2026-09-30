// 発言の整形: 内容は変えず、つなぎ言葉・どもり・すぐの繰り返し・言いかけの切れ端だけを消し、要らない発言（相槌だけ・笑い声だけなど）は発言ごと省く。
// 決まりで確かにわかる所（「えーっと」「まあ」、区切りに挟まれた「その、」、「資料を、資料を」、「あははは」）は決まりで消し、
// つなぎ言葉か中身か見分けの要る所（「でもなんか 良かった」と「なんか食べる」、「こ、コスト」の切れ端、区切りの無い繰り返し）が残る文だけを
// Gemma 4 E2B に 1 文ずつ（前後の発言は渡さない）消させる。モデルが消した所は 1 か所ずつ確かめ、つなぎ言葉・すぐの繰り返し・切れ端だけで
// できていなければ元に戻す（中身は消さない）
import Foundation

/// 1 発言の整形の結果
public struct TidyOutcome: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// 消すものがなかった
        case clean
        /// つなぎ言葉などを消した
        case trimmed
        /// 発言ごと省いた: 相槌だけ・つなぎ言葉だけ・笑い声だけ・文字起こしの誤り（無音に付いた「ご視聴ありがとうございました」など）
        case backchannel, filler, laughter, noise
    }

    public var kind: Kind
    /// 本文の中で消した範囲（UTF-16 の [始め, 終わり)、前から順に）。発言ごと省いたときは空
    public var removed: [[Int]]

    public init(kind: Kind, removed: [[Int]] = []) {
        self.kind = kind
        self.removed = removed
    }

    public var dropped: Bool { kind != .clean && kind != .trimmed }

    /// 整形した本文
    public func apply(to text: String) -> String {
        guard !dropped else { return "" }
        var units = Array(text.utf16)
        for r in removed.reversed() where r[0] >= 0 && r[0] < r[1] && r[1] <= units.count { units.removeSubrange(r[0]..<r[1]) }
        return String(decoding: units, as: UTF16.self)
    }
}

/// 整形する。モデルは要るときに読み込み、unload で外す（actor なので整形は 1 つずつ）
public actor Tidier {
    /// 整形の決まり・モデルへの指示の版（変えたら上げる。保存した結果は、版が違えば使わない）
    public static let version = 2

    public struct Stats: Sendable {
        public var modelCalls = 0
        public var modelSeconds = 0.0
        /// 消すだけでなく書き換えた出力（その文ではモデルの案を使わなかった）
        public var rewrites = 0
        /// モデルが消したが、確かめて元に戻した所
        public var restored = 0
    }

    /// モデルに渡した文と、その出力（確かめる前）
    public struct Exchange: Sendable {
        public let input: String
        public let output: String
    }

    private let folder: URL
    private var model: TextModel?
    public private(set) var stats = Stats()
    /// 最後の tidy でモデルとやり取りした内容（CLI で確かめる用）
    public private(set) var exchanges: [Exchange] = []

    /// modelFolder: Gemma4-E2B-IT-Text-int4 のフォルダ（config.json・model.safetensors・tokenizer.json・chat_template.jinja）
    public init(modelFolder: URL) {
        folder = modelFolder
    }

    public var isLoaded: Bool { model != nil }

    public func load() async throws {
        if model == nil { model = try await TextModel.load(directory: folder) }
    }

    public func unload() {
        model = nil
        TextModel.releaseCachedBuffers()
    }

    /// モデルを使わずに決まる発言なら、その結果（相槌だけの発言や、決まりで消す所しか無い発言。多くの発言がこれで済む）。
    /// モデルに見分けてもらう所があれば nil
    public nonisolated static func quick(_ text: String, previous: String? = nil) -> TidyOutcome? {
        if let kind = TidyRules.drop(text, previous: previous) { return TidyOutcome(kind: kind) }
        let plan = TidyRules.plan(text)
        guard !plan.sentences.contains(where: \.needsModel) else { return nil }
        return TidyRules.finish(plan, proposals: plan.sentences.map(\.sure)).outcome
    }

    /// 1 発言を整形する。previous: 直前の別の話者の発言（問いへの「はい」は答えなので省かない）。取り消されたら CancellationError
    public func tidy(_ text: String, previous: String? = nil) async throws -> TidyOutcome {
        exchanges = []
        if let kind = TidyRules.drop(text, previous: previous) { return TidyOutcome(kind: kind) }
        let plan = TidyRules.plan(text)
        var proposals: [[Bool]] = []
        for sentence in plan.sentences {
            var proposal = sentence.sure
            if sentence.needsModel {
                try Task.checkCancellation()
                try await load()
                guard let model else { break }
                // モデルには決まりで消した後の文を渡す
                let input = String(decoding: sentence.reduced, as: UTF16.self), started = Date()
                let output = try await model.respond(system: TidyPrompt.system, examples: TidyPrompt.examples, prompt: input,
                                                     maxTokens: sentence.reduced.count + 16)
                stats.modelCalls += 1
                stats.modelSeconds += Date().timeIntervalSince(started)
                exchanges.append(Exchange(input: input, output: output))
                let (proposed, unmatched) = TidyRules.modelDeletions(sentence.reduced, output)
                if unmatched <= 2 {
                    for (k, i) in sentence.kept.enumerated() where proposed[k] { proposal[i] = true }
                } else {
                    stats.rewrites += 1
                }
            }
            proposals.append(proposal)
        }
        let (outcome, restored) = TidyRules.finish(plan, proposals: proposals)
        stats.restored += restored
        return outcome
    }
}

/// E2B への指示とお手本（温度 0。お手本は利用者とモデルの前のやり取りとして渡す）
enum TidyPrompt {
    static let system = """
    会議の文字起こしを読みやすくするため、発言から「つなぎ言葉」と「言い直し」を消してください。
    消すもの:
    - つなぎ言葉: えー、えっと、あの、その、まあ、なんか、こう、うーん など、無くても意味が変わらない言葉
    - 言い直し: どもり、すぐに繰り返した同じ言葉、言いかけてやめた切れ端
    消さないもの: 意味のある言葉すべて（「あの人」「その資料」「まあまあ」「なんか食べる」のように中身を指す語も残す）
    消す以外のことはしないでください（言い換え・並べ替え・書き足しをしない）。消した後の発言だけを出力してください。
    """

    static let examples: [(input: String, output: String)] = [
        ("えーっと、あのー、来週の打ち合わせなんですけど、まあ、火曜日でどうですか", "来週の打ち合わせなんですけど、火曜日でどうですか"),
        ("でもなんか 普通に良かったし その 話も面白かった", "でも 普通に良かったし 話も面白かった"),
        ("その、その資料は、えー、まだ確認できてなくて", "その資料は、まだ確認できてなくて"),
        ("いやまあ、それはこう、仕方ないと思う", "いや、それは仕方ないと思う"),
        ("なんか、こ、コストが高いなっていうのは、ありますね", "コストが高いなっていうのは、ありますね"),
        ("みんなで話し合って、話し合った結果、どんどん進めることにした", "みんなで話し合った結果、どんどん進めることにした"),
        ("あの人が言ってたのは、あの、まあまあの結果だったってことです", "あの人が言ってたのは、まあまあの結果だったってことです"),
        ("いや、それは違うと思います", "いや、それは違うと思います"),
    ]
}
