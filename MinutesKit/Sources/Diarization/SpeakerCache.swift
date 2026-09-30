import Foundation

/// Sortformer の話者キャッシュと FIFO。NeMo の SortformerModules.streaming_update_async をバッチ 1 で移植したもの。
/// 大きさは Core ML モデルの固定形状（話者キャッシュ 264・FIFO 40 フレーム）と同じ。Nemotron-3-Diarization の設定
/// （use_learnable_sil_emb: 無音枠は学習済みの埋め込み、spkcache_sil_frames_per_spk: 1）に合わせてある
struct SpeakerCache {
    static let capacity = 264, fifoCapacity = 40, updatePeriod = 300, speakers = 8, dim = 512

    /// 話者キャッシュの埋め込み [capacity][dim]。先頭 count フレームが有効
    private(set) var embs = [Float](repeating: 0, count: capacity * dim)
    private(set) var count = 0
    /// FIFO の埋め込み [fifoCapacity][dim]。先頭 fifoCount フレームが有効
    private(set) var fifo = [Float](repeating: 0, count: fifoCapacity * dim)
    private(set) var fifoCount = 0
    private var preds = [Float](repeating: 0, count: capacity * speakers)  // キャッシュの各フレームの発話確率
    private var compressed = false
    private let silence: [Float]

    init(silence: [Float]) { self.silence = silence }

    /// 1 チャンクの推論結果で状態を進め、チャンクの発話確率 [chunkCapacity][speakers] を返す
    /// - Parameters:
    ///   - output: Core ML の発話確率。[キャッシュ | FIFO | チャンク] の有効フレームを詰めた並び
    ///   - chunkEmbs: チャンクの事前エンコード [フレーム][dim]。有効なのは先頭 embCount フレーム（右文脈を含む）
    ///   - chunkCapacity: 右文脈を除いたチャンクのフレーム数
    mutating func update(output: [Float], chunkEmbs: [Float], embCount: Int, chunkCapacity: Int) -> [Float] {
        let S = Self.speakers, D = Self.dim
        let chunkCount = min(embCount, chunkCapacity)
        let chunkStart = count + fifoCount
        let chunkPreds = Array(output[(chunkStart * S)..<((chunkStart + chunkCount) * S)])
            + [Float](repeating: 0, count: (chunkCapacity - chunkCount) * S)

        // FIFO の後ろにチャンクをつなぎ、あふれた分を先頭から（少なくとも updatePeriod フレーム）話者キャッシュへ移す。
        // FIFO の発話確率は今回の推論のものを使う
        let queued = fifoCount + chunkCount
        let pop = chunkCount == 0 ? fifoCount  // 空のチャンク（音声の終わり）では FIFO を全部移す
            : queued > Self.fifoCapacity ? min(queued, max(Self.updatePeriod, queued - Self.fifoCapacity)) : 0
        let queueEmbs = Array(fifo[..<(fifoCount * D)]) + chunkEmbs[..<(chunkCount * D)]
        let queuePreds = Array(output[(count * S)..<(chunkStart * S)]) + chunkPreds[..<(chunkCount * S)]
        fifo = padded(Array(queueEmbs[(pop * D)...]), to: Self.fifoCapacity * D)
        fifoCount = queued - pop

        // 話者キャッシュに加え、あふれたら圧縮する。初めて圧縮するときだけ、キャッシュの発話確率を今回の推論のものにする
        let total = count + pop
        let cachePreds = !compressed && total > Self.capacity ? output[..<(count * S)] : preds[..<(count * S)]
        let candidateEmbs = Array(embs[..<(count * D)]) + queueEmbs[..<(pop * D)]
        let candidatePreds = Array(cachePreds) + queuePreds[..<(pop * S)]
        if total > Self.capacity {
            (embs, preds) = compress(embs: candidateEmbs, preds: candidatePreds, frames: total)
            compressed = true
        } else {
            embs = padded(candidateEmbs, to: Self.capacity * D)
            preds = padded(candidatePreds, to: Self.capacity * S)
        }
        count = min(total, Self.capacity)
        return chunkPreds
    }

    /// capacity フレームに絞る（NeMo の _compress_spkcache）。どの話者も残るよう、話者ごとに「その話者だけが
    /// はっきり話している」フレームを優先する。並びは話者順（話者の中は時刻順）で、各話者の後ろに無音枠を 1 つ置き、
    /// 足りない分も無音で埋める。同点の順位は NeMo（torch.topk）では決まっていないので、先のフレームを優先する
    private func compress(embs: [Float], preds: [Float], frames n: Int) -> ([Float], [Float]) {
        let S = Self.speakers, D = Self.dim
        let perSpeaker = Self.capacity / S - 1  // 無音枠を除いた 1 話者あたりの枠
        // その話者の確率が高く、ほかの話者の確率が低いほど高いスコア。話していない（確率 0.5 以下）なら -inf
        var scores = [Float](repeating: -.infinity, count: n * S)  // [フレーム][話者]
        for t in 0..<n {
            let p = preds[(t * S)..<(t * S + S)]
            let logAbsent = p.map { log(max(1 - $0, 0.25)) }
            let sumAbsent = logAbsent.reduce(0, +)
            for (s, prob) in zip(0..<S, p) where prob > 0.5 {
                scores[t * S + s] = log(max(prob, 0.25)) - logAbsent[s] + sumAbsent - log(0.5)
            }
        }
        let columns = (0..<S).map { s in Array(stride(from: s, to: n * S, by: S)) }
        // 単独の発話（スコア > 0）が十分ある話者は、重なり（スコア ≤ 0）を使わない
        for column in columns where column.filter({ scores[$0] > 0 }).count >= perSpeaker / 2 {
            for i in column where scores[i] <= 0 { scores[i] = -.infinity }
        }
        for i in (Self.capacity * S)..<(n * S) { scores[i] += 0.05 }  // 新しく加わったフレームを少し優先
        // 各話者の上位フレームを底上げする（強: 3/4 枠に +2 log 2、弱: 3/2 枠に +log 2）
        for (top, boost) in [(perSpeaker * 3 / 4, 2 * Float(log(2.0))), (perSpeaker * 3 / 2, Float(log(2.0)))] {
            for column in columns {
                for i in column.sorted(by: { scores[$0] > scores[$1] || (scores[$0] == scores[$1] && $0 < $1) }).prefix(top) {
                    scores[i] += boost
                }
            }
        }
        // 上位 capacity 個（各話者の無音枠は +inf で必ず入る）を、話者順・時刻順に並べる。frame == n が無音枠
        var ranked: [(score: Float, speaker: Int, frame: Int)] = []
        for s in 0..<S {
            for t in 0..<n where scores[t * S + s] > -.infinity { ranked.append((scores[t * S + s], s, t)) }
            ranked.append((.infinity, s, n))
        }
        let chosen = ranked
            .sorted { $0.score > $1.score || ($0.score == $1.score && ($0.speaker, $0.frame) < ($1.speaker, $1.frame)) }
            .prefix(Self.capacity)
            .sorted { ($0.speaker, $0.frame) < ($1.speaker, $1.frame) }
        let silentPreds = [Float](repeating: 0, count: S)
        var outEmbs: [Float] = [], outPreds: [Float] = []
        for slot in 0..<Self.capacity {
            let t = slot < chosen.count ? chosen[slot].frame : n  // n: 無音（無音枠と、足りない分）
            outEmbs += t < n ? embs[(t * D)..<(t * D + D)] : silence[...]
            outPreds += t < n ? preds[(t * S)..<(t * S + S)] : silentPreds[...]
        }
        return (outEmbs, outPreds)
    }
}

private func padded(_ values: [Float], to count: Int) -> [Float] {
    values + [Float](repeating: 0, count: count - values.count)
}
