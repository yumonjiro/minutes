// 文字起こし: Whisper large-v3（mlx_whisper の Swift 移植、MLX で GPU）。16 kHz モノラルの音声を、語ごとの時刻付きで文字にする。
// 設定（mlx_whisper の transcribe の引数で書くと）:
//   language="ja", word_timestamps=True, temperature=0.0, condition_on_previous_text=False,
//   no_speech_threshold=0.6, logprob_threshold=-1.0, initial_prompt=initialPrompt
// temperature が 1 つなのでやり直しは無く、compression_ratio_threshold は結果に効かない

import Foundation
import MLX

/// Whisper の区間（おおむね文）。時刻は渡した音声の先頭からの秒
public struct WhisperSegment: Sendable, Hashable, Codable {
    public var start: Double
    public var end: Double
    public var text: String
    /// 語ごとの時刻。日本語は 1 トークン（1〜数文字）ずつで、句読点は前の語に付く（mlx-whisper と同じ）
    public var words: [WhisperWord]
}

public struct WhisperWord: Sendable, Hashable, Codable {
    public var text: String
    public var start: Double
    public var end: Double
}

/// Whisper の計算の失敗（メモリが足りずにバッファを確保できなかったときなど）。
/// MLX の既定ではアプリごと終了してしまうので、受け止めてこのエラーにする（処理する側がメモリを空けてやり直せる）
public struct WhisperFailure: LocalizedError {
    public let message: String
    public var errorDescription: String? { "文字起こしの計算に失敗しました（\(message)）" }
}

public actor WhisperTranscriber {
    public static let initialPrompt = "これは日本語の会議の録音です。正確に文字起こししてください。"

    private let folder: URL
    private var pipeline: WhisperPipeline?
    private var loading: Task<WhisperPipeline, Error>?

    /// folder: openai/whisper-large-v3 のファイル（config.json・generation_config.json・model.safetensors・
    /// tokenizer.json・tokenizer_config.json）のあるフォルダ
    public init(folder: URL) {
        self.folder = folder
    }

    public var isLoaded: Bool { pipeline != nil }

    /// モデルを読み込む（読み込み済みなら何もしない）
    public func load() async throws {
        _ = try await loadedPipeline()
    }

    private func loadedPipeline() async throws -> WhisperPipeline {
        if let pipeline { return pipeline }
        let folder = folder
        let task = loading ?? Task {
            // MLX は手放したバッファを再利用のために取っておき、既定ではほぼ上限なく（この Mac で約 15GB まで）溜める。
            // 窓ごとに大きさの違うバッファが溜まり、60 秒の区切りで 2.7GB（使用メモリの最大 5.9GB）になっていた。
            // 256MB に抑えると最大は 3.8GB で、結果も速さも変わらない（エンコーダーの注意の重み 90MB を層ごとに使い回せる大きさ。
            // 20MB では毎層作り直すので CPU 時間が 1 割ほど増えた）。プロセス全体の設定で、LLM（読み込み時に 20MB）とは後の方が効く
            Memory.cacheLimit = 256 * 1024 * 1024
            let model = try mlxErrors { _ in try WhisperModel.load(folder: folder) }
            let tokenizer = try await WhisperTextTokenizer(folder: folder, language: "ja", vocabularySize: model.dims.nVocab)
            return WhisperPipeline(model: model, tokenizer: tokenizer, prompt: Self.initialPrompt)
        }
        loading = task
        do {
            let loaded = try await task.value
            pipeline = loaded
            return loaded
        } catch {
            loading = nil
            throw error
        }
    }

    /// モデルを外して GPU のメモリを空ける（次の transcribe で読み直す）
    public func unload() async {
        _ = try? await loading?.value
        loading = nil
        pipeline = nil
        Memory.clearCache()  // MLX は手放した配列のバッファを再利用のために取っておくので、OS に返す
    }

    /// 16 kHz モノラルの音声（区切り 1 つ）を文字起こしする。計算に失敗したら WhisperFailure
    public func transcribe(_ samples: [Float]) async throws -> [WhisperSegment] {
        let pipeline = try await loadedPipeline()
        let segments = try mlxErrors { error in try pipeline.transcribe(samples, check: error.check) }
        Memory.clearCache()  // 途中の計算に使ったバッファも返す（区切りの間やアプリの他の処理でメモリを空けておく）
        return segments.compactMap { s in
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let words = s.words.compactMap { w -> WhisperWord? in
                let t = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : WhisperWord(text: t, start: w.start, end: w.end)
            }
            return WhisperSegment(start: s.start, end: s.end, text: text, words: words)
        }
    }
}

/// MLX のエラーを WhisperFailure にする（MLX の既定ではプロセスが終了する）。
/// エラーの後の MLX の計算は空の結果を返し続けるので、check で早めに打ち切る
private func mlxErrors<R>(_ body: (ErrorBox) throws -> R) throws -> R {
    do {
        return try withError(body)
    } catch let error as MLXError {
        Memory.clearCache()
        throw WhisperFailure(message: error.localizedDescription)
    }
}

extension WhisperPipeline {
    /// transcribe.py の transcribe: 30 秒の窓をずらしながら文字起こしし、区間と語の時刻を返す。
    /// 窓ごとに check を呼び、MLX の計算が失敗していたらそこで止める
    func transcribe(_ samples: [Float], check: () throws -> Void = {}) throws -> [DecodedSegment] {
        let mel = logMel(samples)
        let contentFrames = mel.dim(0) - Self.windowFrames
        let tb = tokenizer.timestampBegin
        var seek = 0, lastSpeechTimestamp = 0.0
        // condition_on_previous_text=False なので、プロンプトは最初に飛ばさなかった窓にだけ付く
        var prompt = promptTokens
        var result: [DecodedSegment] = []
        while seek < contentFrames {
            let timeOffset = Double(seek * Self.hop) / Double(Self.sampleRate)
            let size = min(Self.windowFrames, contentFrames - seek)
            var segment = mel[seek..<(seek + size)]
            if size < Self.windowFrames { segment = concatenated([segment, MLXArray.zeros([Self.windowFrames - size, mel.dim(1)])]) }
            let decoded = decode(segment.asType(.float16), prompt: prompt)
            try check()
            let tokens = decoded.tokens

            // 無音の窓（<|nospeech|> の確率が高く、平均対数確率も低い）は飛ばす
            if decoded.noSpeechProb > 0.6, !(decoded.avgLogprob > -1.0) {
                seek += size
                continue
            }

            func newSegment(_ start: Double, _ end: Double, _ tokens: [Int]) -> DecodedSegment {
                DecodedSegment(seek: seek, start: start, end: end, text: tokenizer.decode(tokens.filter { $0 < tokenizer.eot }), tokens: tokens)
            }
            var current: [DecodedSegment] = []
            let isTimestamp = tokens.map { $0 >= tb }
            let singleTimestampEnding = isTimestamp.suffix(2) == [false, true]
            let consecutive = isTimestamp.indices.dropFirst().filter { isTimestamp[$0 - 1] && isTimestamp[$0] }
            if !consecutive.isEmpty {
                // 時刻が 2 つ続く所で区間に分ける
                var last = 0
                for slice in consecutive + (singleTimestampEnding ? [tokens.count] : []) {
                    let sliced = Array(tokens[last..<slice])
                    current.append(newSegment(timeOffset + Double(sliced[0] - tb) * 0.02, timeOffset + Double(sliced[sliced.count - 1] - tb) * 0.02, sliced))
                    last = slice
                }
                // 時刻 1 つで終われば窓の残りに発話は無い。そうでなければ最後の区間は途中なので、その手前の時刻から読み直す
                seek += singleTimestampEnding ? size : (tokens[last - 1] - tb) * 2
            } else {
                var duration = Double(size * Self.hop) / Double(Self.sampleRate)
                if let last = tokens.last(where: { $0 >= tb }), last != tb { duration = Double(last - tb) * 0.02 }
                current.append(newSegment(timeOffset, timeOffset + duration, tokens))
                seek += size
            }

            addWordTimestamps(&current, audio: decoded.audio, frames: size, lastSpeechTimestamp: lastSpeechTimestamp)
            try check()
            let lastWordEnd = current.reversed().lazy.compactMap(\.words.last?.end).first ?? current.last?.end
            if !singleTimestampEnding, let lastWordEnd, lastWordEnd > timeOffset {
                seek = Int((lastWordEnd * 100).rounded(.toNearestOrEven))  // 最後の語の終わりから読み直す
            }
            if let lastWordEnd { lastSpeechTimestamp = lastWordEnd }

            for i in current.indices
            where current[i].start == current[i].end || current[i].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                current[i].text = ""
                current[i].tokens = []
                current[i].words = []
            }
            result += current
            prompt = []
        }
        return result
    }
}
