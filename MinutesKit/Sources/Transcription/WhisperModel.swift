// Whisper のモデル（mlx_whisper の whisper.py の移植）。重みは openai/whisper-large-v3 の model.safetensors（fp16、
// transformers の形式）を読み込むときに mlx_whisper の名前へ読み替える。値は mlx_whisper 用の mlx-community/whisper-large-v3-mlx と
// ビット単位で同じ。演算の順序と型も mlx_whisper と同じにして、mlx_whisper と同じ値になるようにする

import Foundation
import MLX
import MLXNN

struct WhisperDimensions {
    var nMels, nAudioCtx, nAudioState, nAudioHead, nAudioLayer: Int
    var nVocab, nTextCtx, nTextState, nTextHead, nTextLayer: Int
}

/// transformers の config.json（WhisperConfig）のうち、形を決める値
private struct TransformersWhisperConfig: Decodable {
    var numMelBins, maxSourcePositions, dModel, encoderAttentionHeads, encoderLayers: Int
    var vocabSize, maxTargetPositions, decoderAttentionHeads, decoderLayers: Int

    var dimensions: WhisperDimensions {
        .init(nMels: numMelBins, nAudioCtx: maxSourcePositions, nAudioState: dModel, nAudioHead: encoderAttentionHeads,
              nAudioLayer: encoderLayers, nVocab: vocabSize, nTextCtx: maxTargetPositions, nTextState: dModel,
              nTextHead: decoderAttentionHeads, nTextLayer: decoderLayers)
    }
}

/// generation_config.json のうち、語の時刻に使う注意ヘッド [[層, ヘッド]]
private struct TransformersGenerationConfig: Decodable {
    var alignmentHeads: [[Int]]
}

/// 層ごとの K/V（自己注意の分はトークンごとに伸び、音声への注意の分は窓の最初に 1 度だけ計算する）
struct LayerCache {
    var keys: MLXArray, values: MLXArray
    var audioKeys: MLXArray, audioValues: MLXArray
}

final class WhisperAttention: Module {
    let heads: Int
    let query: Linear, key: Linear, value: Linear, out: Linear

    init(state: Int, heads: Int) {
        self.heads = heads
        query = Linear(state, state)
        key = Linear(state, state, bias: false)
        value = Linear(state, state)
        out = Linear(state, state)
    }

    /// 出力と softmax 前の注意の重み（語の時刻に使う）を返す
    func callAsFunction(_ x: MLXArray, keys k: MLXArray, values v: MLXArray, mask: MLXArray? = nil) -> (MLXArray, MLXArray) {
        let (batch, length, state) = (x.dim(0), x.dim(1), x.dim(2))
        let scale = pow(Float(state / heads), -0.25)
        let q = query(x).reshaped(batch, length, heads, -1).transposed(0, 2, 1, 3) * scale
        let kt = k.reshaped(batch, k.dim(1), heads, -1).transposed(0, 2, 3, 1) * scale
        let vt = v.reshaped(batch, v.dim(1), heads, -1).transposed(0, 2, 1, 3)
        var qk = matmul(q, kt)
        if let mask { qk = qk + mask[..<length, ..<length] }
        let w = softmax(qk, axis: -1, precise: true)
        return (out(matmul(w, vt).transposed(0, 2, 1, 3).reshaped(batch, length, state)), qk)
    }
}

final class WhisperBlock: Module {
    let attn: WhisperAttention
    @ModuleInfo(key: "attn_ln") var attnLn: LayerNorm
    @ModuleInfo(key: "cross_attn") var crossAttn: WhisperAttention?
    @ModuleInfo(key: "cross_attn_ln") var crossAttnLn: LayerNorm?
    let mlp1: Linear, mlp2: Linear
    @ModuleInfo(key: "mlp_ln") var mlpLn: LayerNorm

    init(state: Int, heads: Int, crossAttention: Bool) {
        attn = WhisperAttention(state: state, heads: heads)
        _attnLn.wrappedValue = LayerNorm(dimensions: state)
        _crossAttn.wrappedValue = crossAttention ? WhisperAttention(state: state, heads: heads) : nil
        _crossAttnLn.wrappedValue = crossAttention ? LayerNorm(dimensions: state) : nil
        mlp1 = Linear(state, state * 4)
        mlp2 = Linear(state * 4, state)
        _mlpLn.wrappedValue = LayerNorm(dimensions: state)
    }

    /// エンコーダーの層
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let h = attnLn(x)
        var x = x + attn(h, keys: attn.key(h), values: attn.value(h)).0
        x = x + mlp2(gelu(mlp1(mlpLn(x))))
        return x
    }

    /// デコーダーの層。cache が無ければ音声への注意の K/V を audio から計算する
    func callAsFunction(_ x: MLXArray, audio: MLXArray, mask: MLXArray, cache: LayerCache?) -> (MLXArray, LayerCache, MLXArray) {
        guard let crossAttn, let crossAttnLn else { fatalError("decoder block without cross attention") }
        let h = attnLn(x)
        var keys = attn.key(h), values = attn.value(h)
        if let cache {
            keys = concatenated([cache.keys, keys], axis: 1)
            values = concatenated([cache.values, values], axis: 1)
        }
        var x = x + attn(h, keys: keys, values: values, mask: mask).0
        let audioKeys = cache?.audioKeys ?? crossAttn.key(audio), audioValues = cache?.audioValues ?? crossAttn.value(audio)
        let (y, qk) = crossAttn(crossAttnLn(x), keys: audioKeys, values: audioValues)
        x = x + y
        x = x + mlp2(gelu(mlp1(mlpLn(x))))
        return (x, LayerCache(keys: keys, values: values, audioKeys: audioKeys, audioValues: audioValues), qk)
    }
}

final class AudioEncoder: Module {
    let conv1: Conv1d, conv2: Conv1d
    let blocks: [WhisperBlock]
    @ModuleInfo(key: "ln_post") var lnPost: LayerNorm
    private let _positionalEmbedding: MLXArray

    init(_ d: WhisperDimensions) {
        conv1 = Conv1d(inputChannels: d.nMels, outputChannels: d.nAudioState, kernelSize: 3, padding: 1)
        conv2 = Conv1d(inputChannels: d.nAudioState, outputChannels: d.nAudioState, kernelSize: 3, stride: 2, padding: 1)
        blocks = (0..<d.nAudioLayer).map { _ in WhisperBlock(state: d.nAudioState, heads: d.nAudioHead, crossAttention: false) }
        _lnPost.wrappedValue = LayerNorm(dimensions: d.nAudioState)
        _positionalEmbedding = sinusoids(length: d.nAudioCtx, channels: d.nAudioState).asType(.float16)
    }

    /// mel: [1, 3000, n_mels]（fp16）→ [1, 1500, n_audio_state]
    func callAsFunction(_ mel: MLXArray) -> MLXArray {
        var x = gelu(conv2(gelu(conv1(mel)))) + _positionalEmbedding
        for block in blocks { x = block(x) }
        return lnPost(x)
    }
}

final class TextDecoder: Module {
    @ModuleInfo(key: "token_embedding") var tokenEmbedding: Embedding
    @ParameterInfo(key: "positional_embedding") var positionalEmbedding: MLXArray
    let blocks: [WhisperBlock]
    let ln: LayerNorm
    private let _mask: MLXArray

    init(_ d: WhisperDimensions) {
        _tokenEmbedding.wrappedValue = Embedding(embeddingCount: d.nVocab, dimensions: d.nTextState)
        _positionalEmbedding.wrappedValue = MLXArray.zeros([d.nTextCtx, d.nTextState])
        blocks = (0..<d.nTextLayer).map { _ in WhisperBlock(state: d.nTextState, heads: d.nTextHead, crossAttention: true) }
        ln = LayerNorm(dimensions: d.nTextState)
        _mask = MultiHeadAttention.createAdditiveCausalMask(d.nTextCtx).asType(.float16)
    }

    /// tokens: [1, n]。logits（fp16）・更新した K/V・層ごとの音声への注意の重み（softmax 前）を返す
    func callAsFunction(_ tokens: MLXArray, audio: MLXArray, cache: [LayerCache]?) -> (MLXArray, [LayerCache], [MLXArray]) {
        let offset = cache?.first?.keys.dim(1) ?? 0
        var x = tokenEmbedding(tokens) + positionalEmbedding[offset..<(offset + tokens.dim(-1))]
        var newCache: [LayerCache] = [], crossQK: [MLXArray] = []
        for (i, block) in blocks.enumerated() {
            let (y, layerCache, qk) = block(x, audio: audio, mask: _mask, cache: cache?[i])
            x = y
            newCache.append(layerCache)
            crossQK.append(qk)
        }
        return (tokenEmbedding.asLinear(ln(x)), newCache, crossQK)
    }
}

final class WhisperModel: Module {
    let encoder: AudioEncoder
    let decoder: TextDecoder
    let dims: WhisperDimensions
    /// 語の時刻に使う注意ヘッド [層, ヘッド]（generation_config.json の alignment_heads。large-v3 は 10 個）
    private(set) var alignmentHeads: [(layer: Int, head: Int)] = []

    private init(_ d: WhisperDimensions) {
        dims = d
        encoder = AudioEncoder(d)
        decoder = TextDecoder(d)
    }

    /// folder: openai/whisper-large-v3 の config.json・generation_config.json・model.safetensors
    static func load(folder: URL) throws -> WhisperModel {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let config = try decoder.decode(TransformersWhisperConfig.self, from: Data(contentsOf: folder.appending(path: "config.json")))
        let generation = try decoder.decode(TransformersGenerationConfig.self,
                                            from: Data(contentsOf: folder.appending(path: "generation_config.json")))
        let model = WhisperModel(config.dimensions)
        model.alignmentHeads = generation.alignmentHeads.map { ($0[0], $0[1]) }
        let weights = try loadArrays(url: folder.appending(path: "model.safetensors"))
        try model.update(parameters: ModuleParameters.unflattened(mlxWhisperWeights(weights)), verify: [.all])
        eval(model)
        return model
    }
}

/// transformers の重みの名前と形を mlx_whisper（convert.py の変換結果）に揃える。
/// エンコーダーの位置埋め込み（mlx_whisper は sinusoids で作る）と出力層（トークン埋め込みと共有）は使わない
private func mlxWhisperWeights(_ weights: [String: MLXArray]) -> [String: MLXArray] {
    let renames: [(String, String)] = [
        ("model.encoder.layers.", "encoder.blocks."), ("model.decoder.layers.", "decoder.blocks."),
        ("model.encoder.layer_norm.", "encoder.ln_post."), ("model.decoder.layer_norm.", "decoder.ln."),
        ("model.decoder.embed_tokens.", "decoder.token_embedding."),
        ("model.decoder.embed_positions.weight", "decoder.positional_embedding"),
        ("model.encoder.", "encoder."),
        (".self_attn_layer_norm.", ".attn_ln."), (".encoder_attn_layer_norm.", ".cross_attn_ln."), (".final_layer_norm.", ".mlp_ln."),
        (".self_attn.", ".attn."), (".encoder_attn.", ".cross_attn."),
        (".q_proj.", ".query."), (".k_proj.", ".key."), (".v_proj.", ".value."), (".out_proj.", ".out."),
        (".fc1.", ".mlp1."), (".fc2.", ".mlp2."),
    ]
    var result: [String: MLXArray] = [:]
    for (key, value) in weights where key != "proj_out.weight" && key != "model.encoder.embed_positions.weight" {
        var name = key
        for (from, to) in renames { name = name.replacingOccurrences(of: from, with: to) }
        // 畳み込みの重みは PyTorch が [出力, 入力, 幅]、MLX が [出力, 幅, 入力]
        result[name] = name.hasPrefix("encoder.conv") && name.hasSuffix(".weight") ? value.transposed(0, 2, 1) : value
    }
    return result
}

/// エンコーダーの位置埋め込み（mlx_whisper の sinusoids。係数は倍精度、表は float32 で計算する）
private func sinusoids(length: Int, channels: Int) -> MLXArray {
    let increment = Float(-log(10000.0) / Double(channels / 2 - 1))
    let inverse = exp(increment * MLXArray(0..<(channels / 2)).asType(.float32))
    let scaled = MLXArray(0..<length).asType(.float32)[0..., .newAxis] * inverse[.newAxis, 0...]
    return concatenated([sin(scaled), cos(scaled)], axis: 1)
}
