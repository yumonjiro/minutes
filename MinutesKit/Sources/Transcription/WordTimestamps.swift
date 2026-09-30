// 語ごとの時刻（mlx_whisper の timing.py の移植）。文字起こしたトークンをもう一度デコーダーに通し、
// 語の時刻用の注意ヘッドの重みを DTW でたどって、語の開始・終了にする

import Foundation
import MLX

/// 窓の中の区間（transcribe.py の segment。時刻は渡した音声の先頭からの秒）
struct DecodedSegment {
    var seek: Int
    var start: Double
    var end: Double
    var text: String
    var tokens: [Int]
    var words: [WhisperWord] = []
}

struct AlignedWord {
    var word: String
    var tokens: [Int]
    var start: Double
    var end: Double
}

private let prependPunctuations = "\"'“¿([{-"
private let appendPunctuations = "\"'.。,，!！?？:：”)]}、"
private let sentenceEndMarks = ".。!！?？"

extension WhisperPipeline {
    /// add_word_timestamps: segments の語の時刻を求め、区間の開始・終了も語に合わせる。
    /// audio は窓のエンコーダーの出力、frames は窓の音声のあるフレーム数
    func addWordTimestamps(_ segments: inout [DecodedSegment], audio: MLXArray, frames: Int, lastSpeechTimestamp: Double) {
        guard !segments.isEmpty else { return }
        let textTokens = segments.map { $0.tokens.filter { $0 < tokenizer.eot } }
        var alignment = findAlignment(textTokens.flatMap { $0 }, audio: audio, frames: frames)
        let durations = alignment.map { $0.end - $0.start }.filter { $0 != 0 }
        let medianDuration = min(0.7, median(durations))
        let maxDuration = medianDuration * 2

        // 文末の記号の語が長すぎれば詰める
        if !durations.isEmpty {
            for i in alignment.indices.dropFirst() where alignment[i].end - alignment[i].start > maxDuration {
                if pythonIn(alignment[i].word, sentenceEndMarks) {
                    alignment[i].end = alignment[i].start + maxDuration
                } else if pythonIn(alignment[i - 1].word, sentenceEndMarks) {
                    alignment[i].start = alignment[i].end - maxDuration
                }
            }
        }
        mergePunctuations(&alignment)

        let timeOffset = Double(segments[0].seek * Self.hop) / Double(Self.sampleRate)
        var lastSpeechTimestamp = lastSpeechTimestamp
        var index = 0
        for (s, tokens) in textTokens.enumerated() {
            var saved = 0
            var words: [WhisperWord] = []
            while index < alignment.count, saved < tokens.count {
                let timing = alignment[index]
                if !timing.word.isEmpty {
                    words.append(WhisperWord(text: timing.word, start: round2(timeOffset + timing.start), end: round2(timeOffset + timing.end)))
                }
                saved += timing.tokens.count
                index += 1
            }
            if !words.isEmpty {
                // 間が空いた後の最初の 2 語が長すぎれば詰める
                if words[0].end - lastSpeechTimestamp > medianDuration * 4,
                   words[0].end - words[0].start > maxDuration || (words.count > 1 && words[1].end - words[0].start > maxDuration * 2) {
                    if words.count > 1, words[1].end - words[1].start > maxDuration {
                        let boundary = max(words[1].end / 2, words[1].end - maxDuration)
                        words[0].end = boundary
                        words[1].start = boundary
                    }
                    words[0].start = max(0, words[0].end - maxDuration)
                }
                // 最初・最後の語が長すぎれば区間の時刻を使い、そうでなければ区間を語に合わせる
                if segments[s].start < words[0].end, segments[s].start - 0.5 > words[0].start {
                    words[0].start = max(0, min(words[0].end - medianDuration, segments[s].start))
                } else {
                    segments[s].start = words[0].start
                }
                let last = words.count - 1
                if segments[s].end > words[last].start, segments[s].end + 0.5 < words[last].end {
                    words[last].end = max(words[last].start + medianDuration, segments[s].end)
                } else {
                    segments[s].end = words[last].end
                }
                lastSpeechTimestamp = segments[s].end
            }
            segments[s].words = words
        }
    }

    /// find_alignment: トークンごとの注意の重みを、ヘッドごとにトークン間で標準化して時間方向に幅 7 の中央値フィルタをかけ、
    /// ヘッドの平均を DTW でたどる。語の開始・終了は、その語の最初のトークンと次の語の最初のトークンの行に入った時刻
    private func findAlignment(_ textTokens: [Int], audio: MLXArray, frames: Int) -> [AlignedWord] {
        guard !textTokens.isEmpty else { return [] }
        let tokens = tokenizer.sotSequence + [tokenizer.noTimestamps] + textTokens + [tokenizer.eot]
        let (_, _, crossQK) = model.decoder(MLXArray(tokens.map(Int32.init))[.newAxis], audio: audio, cache: nil)
        var weights = stacked(model.alignmentHeads.map { crossQK[$0.layer][0, $0.head] })[0..., 0..., ..<(frames / 2)]
        weights = softmax(weights, axis: -1, precise: true).asType(.float32)
        let mean = weights.mean(axis: -2, keepDims: true)
        let std = weights.variance(axis: -2, keepDims: true, ddof: 0).sqrt()
        weights = (weights - mean) / std
        let (heads, n, m) = (weights.dim(0), weights.dim(1), weights.dim(2))
        let values = weights.asArray(Float.self)

        // 中央値フィルタ（端は折り返す。3 フレーム以下ならかけない）とヘッドの平均（numpy と同じくヘッドの順に足して割る）
        var matrix = [Float](repeating: 0, count: n * m)
        var window = [Float](repeating: 0, count: 7)
        for h in 0..<heads {
            for i in 0..<n {
                let row = (h * n + i) * m
                for j in 0..<m {
                    var value = values[row + j]
                    if m > 3 {
                        for k in 0..<7 {
                            let x = abs(j + k - 3)
                            window[k] = values[row + (x < m ? x : 2 * (m - 1) - x)]
                        }
                        window.sort()
                        value = window[3]
                    }
                    matrix[i * m + j] += value
                }
            }
        }
        // 行は <|notimestamps|> と文字のトークン（それぞれ次のトークンを予測した位置）
        let first = tokenizer.sotSequence.count, rows = n - first - 1
        let jumps = dtw(rows: rows, columns: m) { i, j in -(matrix[(first + i) * m + j] / Float(heads)) }

        let (words, wordTokens) = tokenizer.splitToWordTokens(textTokens + [tokenizer.eot])
        guard wordTokens.count > 1 else { return [] }
        var alignment: [AlignedWord] = []
        var start = 0
        for (word, tokens) in zip(words, wordTokens).dropLast() {
            let end = start + tokens.count
            alignment.append(AlignedWord(word: word, tokens: tokens, start: Double(jumps[start]) / 50, end: Double(jumps[end]) / 50))
            start = end
        }
        return alignment
    }
}

/// openai の DTW（同じ値なら「左」を選ぶ癖も同じ）。行ごとに、経路が最初にその行に入った列を返す
private func dtw(rows: Int, columns: Int, cost x: (Int, Int) -> Float) -> [Int] {
    let width = columns + 1
    var cost = [Float](repeating: .infinity, count: (rows + 1) * width)
    var trace = [UInt8](repeating: 2, count: (rows + 1) * width)  // 0: 斜め, 1: 上, 2: 左
    cost[0] = 0
    for j in 1...columns {
        for i in 1...rows {
            let c0 = cost[(i - 1) * width + j - 1], c1 = cost[(i - 1) * width + j], c2 = cost[i * width + j - 1]
            let (c, t): (Float, UInt8) = c0 < c1 && c0 < c2 ? (c0, 0) : c1 < c0 && c1 < c2 ? (c1, 1) : (c2, 2)
            cost[i * width + j] = x(i - 1, j - 1) + c
            trace[i * width + j] = t
        }
    }
    for i in 0...rows { trace[i * width] = 1 }
    var jumps = [Int](repeating: 0, count: rows)
    var i = rows, j = columns
    while i > 0 || j > 0 {
        if i > 0 { jumps[i - 1] = j - 1 }  // 後ろからたどるので、最後に書いた値がその行の最初の列
        switch trace[i * width + j] {
        case 0: i -= 1; j -= 1
        case 1: i -= 1
        default: j -= 1
        }
    }
    return jumps
}

/// merge_punctuations: 前に付く記号は次の語へ、後に付く句読点は前の語へ
private func mergePunctuations(_ alignment: inout [AlignedWord]) {
    var following = alignment.count - 1
    for previous in stride(from: alignment.count - 2, through: 0, by: -1) {
        let word = alignment[previous].word
        if word.hasPrefix(" "), pythonIn(word.trimmingCharacters(in: .whitespacesAndNewlines), prependPunctuations) {
            alignment[following].word = word + alignment[following].word
            alignment[following].tokens = alignment[previous].tokens + alignment[following].tokens
            alignment[previous].word = ""
            alignment[previous].tokens = []
        } else {
            following = previous
        }
    }
    var previous = 0
    for following in alignment.indices.dropFirst() {
        if !alignment[previous].word.hasSuffix(" "), pythonIn(alignment[following].word, appendPunctuations) {
            alignment[previous].word += alignment[following].word
            alignment[previous].tokens += alignment[following].tokens
            alignment[following].word = ""
            alignment[following].tokens = []
        } else {
            previous = following
        }
    }
}

/// Python の `a in b`（部分文字列。空文字列は常に含まれる）
private func pythonIn(_ a: String, _ b: String) -> Bool { a.isEmpty || b.contains(a) }

/// numpy.median（空なら 0）
private func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted(), k = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[k] : (sorted[k - 1] + sorted[k]) / 2
}

/// Python の round(x, 2)
func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
