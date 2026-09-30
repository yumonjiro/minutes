// 音声の特徴量（mlx_whisper の audio.py）と、30 秒の窓 1 つの文字起こし（decoding.py の DecodingTask）。
// このアプリの設定（temperature 0 の貪欲法・時刻あり・suppress_tokens "-1"・suppress_blank・max_initial_timestamp 1.0）で通る所だけ。
// logits の規則は mlx_whisper と同じ MLX の演算で行う（時刻が戻らない規則は mlx_whisper では働いていないので無い）

import Foundation
import MLX

/// 窓 1 つの結果
struct WindowResult {
    /// エンコーダーの出力（語の時刻にも使う）
    var audio: MLXArray
    /// 生成したトークン（<|endoftext|> の手前まで）
    var tokens: [Int]
    var avgLogprob: Double
    var noSpeechProb: Double
}

/// 読み込んだモデルと、窓に共通の表（作った後は変更しないので、読み込みの Task から渡してよい）
final class WhisperPipeline: @unchecked Sendable {
    static let sampleRate = 16000, hop = 160, nFFT = 400
    static let windowFrames = 3000  // 30 秒
    static let maxInitialTimestamp = 50  // 最初の時刻は 1.0 秒まで（0.02 秒刻み）

    let model: WhisperModel
    let tokenizer: WhisperTextTokenizer
    /// 最初の窓に付けるプロンプト（" " + initial_prompt）
    let promptTokens: [Int]
    private let window: MLXArray, melFilters: MLXArray
    private let suppress: MLXArray, suppressAtBegin: MLXArray  // SuppressTokens（最初のトークンでは SuppressBlank も）
    private let timestampRules: [MLXArray]  // ApplyTimestampRules の固定の部分（applyRules の rule の番号順）
    private let isText: MLXArray

    init(model: WhisperModel, tokenizer: WhisperTextTokenizer, prompt: String) {
        self.model = model
        self.tokenizer = tokenizer
        promptTokens = tokenizer.encode(" " + prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        // numpy.hanning(401)[:-1] と同じ式
        window = MLXArray((0..<Self.nFFT).map { Float(0.5 + 0.5 * cos(Double.pi * Double(2 * $0 - Self.nFFT) / Double(Self.nFFT))) })
        melFilters = slaneyMelFilters(bins: model.dims.nMels, nFFT: Self.nFFT, sampleRate: Self.sampleRate)

        let n = model.dims.nVocab, t = tokenizer
        func mask(_ ranges: [Range<Int>]) -> MLXArray {
            var m = [Float](repeating: 0, count: n)
            for range in ranges { for i in range.clamped(to: 0..<n) { m[i] = -.infinity } }
            return MLXArray(m)[.newAxis]
        }
        let suppressed = t.suppressTokens.map { $0..<($0 + 1) }
        suppress = mask(suppressed)
        suppressAtBegin = mask(suppressed + (t.encode(" ") + [t.eot]).map { $0..<($0 + 1) })
        let noTimestamps = t.noTimestamps..<(t.noTimestamps + 1)
        timestampRules = [
            mask([noTimestamps]),
            mask([noTimestamps, t.timestampBegin..<n]),  // 時刻が 2 つ続いた後は文字か <|endoftext|>
            mask([noTimestamps, 0..<t.eot]),  // 時刻 1 つの後は時刻（区間の終わり）か <|endoftext|>
            mask([noTimestamps, 0..<t.timestampBegin, (t.timestampBegin + Self.maxInitialTimestamp + 1)..<n]),  // 最初
        ]
        isText = (MLXArray(0..<n) .< t.timestampBegin)[.newAxis]
    }

    /// log-mel（audio.py の log_mel_spectrogram。末尾に 30 秒の無音を足す）。[フレーム, n_mels]（float32）
    func logMel(_ samples: [Float]) -> MLXArray {
        let padded = samples + [Float](repeating: 0, count: Self.windowFrames * Self.hop)
        let half = Self.nFFT / 2  // 両端は折り返し
        let x = Array(padded[1...half].reversed()) + padded + Array(padded[(padded.count - half - 1)..<(padded.count - 1)].reversed())
        let frames = (x.count - Self.nFFT + Self.hop) / Self.hop
        let spectrum = rfft(asStrided(MLXArray(x), [frames, Self.nFFT], strides: [Self.hop, 1]) * window)
        let mel = matmul(abs(spectrum[..<(frames - 1)]).square(), melFilters.T)
        let logSpec = log10(maximum(mel, Float(1e-10)))
        return (maximum(logSpec, logSpec.max() - 8) + 4) / 4
    }

    /// 30 秒の窓（[3000, n_mels] の fp16）を文字起こしする。prompt が空でなければ <|startofprev|> を付けて前に置く
    func decode(_ mel: MLXArray, prompt: [Int]) -> WindowResult {
        let audio = model.encoder(mel[.newAxis])
        let sampleLength = model.dims.nTextCtx / 2
        let initial = (prompt.isEmpty ? [] : [tokenizer.sotPrev] + prompt.suffix(sampleLength - 1)) + tokenizer.sotSequence
        let sampleBegin = initial.count, sotIndex = initial.count - tokenizer.sotSequence.count
        var tokens = initial, cache: [LayerCache]?, sumLogprob: Float = 0, noSpeechProb: Float = 0
        var input = MLXArray(initial.map(Int32.init))[.newAxis]
        for _ in 0..<sampleLength {
            let (output, updated, _) = model.decoder(input, audio: audio, cache: cache)
            cache = updated
            let logits = output.asType(.float32)
            let filtered = applyRules(logits[0..., -1], tokens: tokens, sampleBegin: sampleBegin)
            let next = argMax(filtered, axis: -1)
            let logprob = takeAlong(filtered - logSumExp(filtered, axis: -1, keepDims: true), next[0..., .newAxis], axis: -1)
            if tokens.count == sampleBegin {
                // <|nospeech|> の確率は <|startoftranscript|> の位置の出力から
                let noSpeech = softmax(logits[0, sotIndex], axis: -1)[tokenizer.noSpeech]
                eval(next, logprob, noSpeech)
                noSpeechProb = noSpeech.item(Float.self)
            } else {
                eval(next, logprob)
            }
            let token = next.item(Int.self)
            sumLogprob += logprob.item(Float.self)
            tokens.append(token)
            if token == tokenizer.eot { break }
            input = next[.newAxis]
        }
        let sampled = Array(tokens[sampleBegin...].prefix { $0 != tokenizer.eot })
        return WindowResult(audio: audio, tokens: sampled, avgLogprob: Double(sumLogprob) / Double(sampled.count + 1),
                            noSpeechProb: Double(noSpeechProb))
    }

    /// SuppressBlank・SuppressTokens・ApplyTimestampRules（logits は [1, 語彙]）
    private func applyRules(_ logits: MLXArray, tokens: [Int], sampleBegin: Int) -> MLXArray {
        let begin = tokens.count == sampleBegin
        let logits = logits + (begin ? suppressAtBegin : suppress)
        let tb = tokenizer.timestampBegin
        let rule: Int
        if begin {
            rule = 3
        } else if tokens[tokens.count - 1] >= tb {
            rule = tokens.count - sampleBegin < 2 || tokens[tokens.count - 2] >= tb ? 1 : 2
        } else {
            rule = 0
        }
        // 時刻トークン全体の確率が、どの文字のトークンよりも高ければ時刻にする
        let logprobs = logits - logSumExp(logits, axis: -1, keepDims: true)
        let timestamp = logSumExp(logprobs[0..., tb...], axis: -1, keepDims: true)
        let maxText = logprobs[0..., ..<tb].max(axis: -1, keepDims: true)
        return which((timestamp .> maxText) .&& isText, Float(-Float.infinity), logits + timestampRules[rule])
    }
}

/// librosa.filters.mel(sr, n_fft, n_mels, norm="slaney")（mlx_whisper の assets/mel_filters.npz と同じ値）。[bins, n_fft/2+1]
private func slaneyMelFilters(bins: Int, nFFT: Int, sampleRate: Int) -> MLXArray {
    // Slaney のメル尺度: 1 kHz までは線形、それより上は対数
    let fSp = 200.0 / 3, minLogMel = 1000 / fSp, logStep = log(6.4) / 27
    func mel(_ hz: Double) -> Double { hz < 1000 ? hz / fSp : minLogMel + log(hz / 1000) / logStep }
    func hz(_ mel: Double) -> Double { mel < minLogMel ? mel * fSp : 1000 * exp(logStep * (mel - minLogMel)) }
    let top = mel(Double(sampleRate) / 2), step = top / Double(bins + 1)
    let edges = (0...(bins + 1)).map { hz($0 == bins + 1 ? top : Double($0) * step) }  // numpy.linspace と同じ
    let freqs = nFFT / 2 + 1
    var filters = [Float](repeating: 0, count: bins * freqs)
    for m in 0..<bins {
        let norm = 2 / (edges[m + 2] - edges[m])
        for k in 0..<freqs {
            let f = Double(k * sampleRate) / Double(nFFT)
            let w = max(0, min((f - edges[m]) / (edges[m + 1] - edges[m]), (edges[m + 2] - f) / (edges[m + 2] - edges[m + 1])))
            filters[m * freqs + k] = Float(Double(Float(w)) * norm)  // librosa は三角形を float32 にしてから正規化する
        }
    }
    return MLXArray(filters, [bins, freqs])
}
