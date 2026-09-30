// Gemma 4 E2B のテキスト専用版（mlx-community/Gemma4-E2B-IT-Text-int4、MLX）で、会話への応答を作る。
// 画像・音声の重みを持たないので小さい（2.5GB）。KV を使い回す層の使われない重みは mlx-swift-lm が読み込み時に除く
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// 読み込んだモデル。毎回同じ前置き（指示とお手本）の KV を一度だけ計算して写しを使い回し、発言の部分だけを処理する。
/// 生成は同時に 1 つだけ呼ぶこと（Tidier が順番にする。前置きの KV はそれを前提に同期なしで持つ）
final class TextModel: @unchecked Sendable {
    private let container: ModelContainer
    private var prefix: Prefix?

    /// 前置きのトークンと、それを処理した後の KV
    private struct Prefix {
        let system: String
        let examples: [String]
        let tokens: [Int]
        let cache: [KVCache]
    }

    private init(container: ModelContainer) {
        self.container = container
    }

    /// directory: config.json・model.safetensors・tokenizer.json・chat_template.jinja を入れたフォルダ（ネットワークは使わない）
    static func load(directory: URL) async throws -> TextModel {
        // mlx-swift-lm は生成中にバッファのキャッシュを空けないので、そのままでは整形を続けるうちに何 GB も溜まる。
        // 20MB に抑えても速さは変わらなかった（LocalLLM で測った値。Whisper とは同時に読み込まないので、プロセス全体の設定でよい）
        Memory.cacheLimit = 20 * 1024 * 1024
        return TextModel(container: try await factory.loadContainer(from: directory, using: TokenizerLoader()))
    }

    /// このモデルの config.json は設定を text_config の中に置くが、mlx-swift-lm（3.31.4）の Gemma4Text は上の階層しか読まず既定値で組み立てる。
    /// 既定値の多くは E2B と同じだが、全体を見る層の RoPE の回転の割合（partial_rotary_factor）が 0.25 でなく 1.0 になり、出力が崩れる
    /// （つなぎ言葉をほとんど消さなかった。mlx-lm の Python 版は既定値が 0.25 で正しく動く）。text_config を上の階層に広げてから読む
    private static let factory = LLMModelFactory(
        typeRegistry: ModelTypeRegistry(creators: [
            "gemma4_text": { data in
                var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                if let text = json["text_config"] as? [String: Any] { json.merge(text) { _, nested in nested } }
                let configuration = try JSONDecoder().decode(Gemma4TextConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
                return Gemma4TextModel(configuration)
            }
        ]),
        modelRegistry: LLMRegistry.shared)

    /// system とお手本（利用者の発言とその応答）のあとの、prompt への応答（温度 0）
    func respond(system: String, examples: [(input: String, output: String)], prompt: String, maxTokens: Int) async throws -> String {
        let pairs = examples.flatMap { [$0.input, $0.output] }
        let text = try await container.perform { context in
            let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0, prefillStepSize: 2048)
            func tokens(_ last: String) async throws -> [Int] {
                var chat: [Chat.Message] = [.system(system)]
                for (i, content) in pairs.enumerated() { chat.append(i % 2 == 0 ? .user(content) : .assistant(content)) }
                chat.append(.user(last))
                let input = try await context.processor.prepare(input: UserInput(chat: chat, additionalContext: ["enable_thinking": false]))
                return input.text.tokens.asArray(Int.self)
            }
            // 前置き: 最後の発言だけを変えた 2 つの入力で、共通する頭の部分
            if self.prefix?.system != system || self.prefix?.examples != pairs {
                let a = try await tokens("A"), b = try await tokens("B")
                let shared = Array(zip(a, b).prefix { $0 == $1 }.map(\.0))
                let cache = context.model.newCache(parameters: parameters)
                _ = try TokenIterator(input: LMInput(tokens: MLXArray(shared)), model: context.model, cache: cache, parameters: parameters)
                eval(cache.flatMap(\.state))
                self.prefix = Prefix(system: system, examples: pairs, tokens: shared, cache: cache)
            }
            let full = try await tokens(prompt)
            var input = LMInput(tokens: MLXArray(full)), cache: [KVCache]? = nil
            if let prefix = self.prefix, full.count > prefix.tokens.count, full.starts(with: prefix.tokens) {
                input = LMInput(tokens: MLXArray(Array(full[prefix.tokens.count...])))
                cache = prefix.cache.map { $0.copy() }
            }
            var text = ""
            for await generation in try MLXLMCommon.generate(input: input, cache: cache, parameters: parameters, context: context) {
                if case .chunk(let chunk) = generation { text += chunk }
            }
            return text
        }
        try Task.checkCancellation()
        return text
    }

    /// MLX が手放したバッファを OS に返す（モデルを外した後に呼ぶ）
    static func releaseCachedBuffers() {
        Memory.clearCache()
    }
}

/// モデルのフォルダにある tokenizer.json・chat_template.jinja を swift-transformers で読む
private struct TokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

/// swift-transformers のトークナイザを MLXLMCommon の形に合わせる
private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
