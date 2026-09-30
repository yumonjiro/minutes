import CoreML
import Foundation

/// 話者の発話区間（秒）。speaker は 0〜7 の話者スロット
public struct SpeakerTurn: Sendable, Codable, Hashable {
    public var start: Double
    public var end: Double
    public var speaker: Int

    public init(start: Double, end: Double, speaker: Int) {
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

public struct DiarizationResult: Sendable, Codable {
    /// フレームごとの話者別の発話確率 [フレーム][8]
    public var probs: [[Float]]
    /// 1 フレームの秒数（0.08）
    public var frameSec: Double
    /// 発話確率が 0.5 を超える区間（開始時刻順）
    public var turns: [SpeakerTurn]

    public init(probs: [[Float]], frameSec: Double, turns: [SpeakerTurn]) {
        self.probs = probs
        self.frameSec = frameSec
        self.turns = turns
    }
}

public struct DiarizationError: LocalizedError {
    public let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Nemotron-3-Diarization（ストリーミング Sortformer、最大 8 話者）による話者分離。
/// ネットワーク（altic-dev/nemotron-3-diarization-coreml）だけを Core ML で動かし、特徴量・チャンク分割・
/// 話者キャッシュの更新は NeMo と同じ計算をここで行う。
/// 設定はモデルカードの offline（チャンク 27.2 秒 + 右文脈 3.2 秒）。
/// 状態は diarize の中だけに持つので、1 つのインスタンスを複数のスレッドから使える（推論はロックで順に行う）
public final class NemotronDiarizer: @unchecked Sendable {
    public static let frameSec = 0.08
    private static let subsampling = 8, chunkLen = 340, rightContext = 40  // 単位は 80 ms フレーム
    private static let inputFrames = (chunkLen + rightContext) * subsampling  // Core ML の入力は 3040 特徴量フレーム固定

    private let model: MLModel
    private let silence: [Float]
    private let lock = NSLock()

    /// - Parameters:
    ///   - modelURL: コンパイル済みの .mlmodelc（アプリに同梱する形）か .mlpackage（コンパイルして Caches に置く）
    ///   - silenceEmbeddingURL: 話者キャッシュの無音枠に入れる学習済みの埋め込み（learnable_sil_emb.f32）
    public init(modelURL: URL, silenceEmbeddingURL: URL, computeUnits: MLComputeUnits = .cpuAndGPU) throws {
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        model = try MLModel(contentsOf: Self.compiled(modelURL), configuration: config)
        let data = try Data(contentsOf: silenceEmbeddingURL)
        guard data.count == SpeakerCache.dim * MemoryLayout<Float>.size else {
            throw DiarizationError("無音の埋め込みの大きさが違います: \(silenceEmbeddingURL.path)")
        }
        var silence = [Float](repeating: 0, count: SpeakerCache.dim)
        _ = silence.withUnsafeMutableBytes { data.copyBytes(to: $0) }  // float32 リトルエンディアン
        self.silence = silence
    }

    /// 16 kHz モノラルの音声を話者分離する。progress には処理済みの割合（0〜1）がチャンクごとに届く
    public func diarize(_ samples: [Float], progress: (@Sendable (Double) -> Void)? = nil) throws -> DiarizationResult {
        let mel = try LogMel()
        let (valid, total) = LogMel.frameCounts(samples: samples.count)
        var cache = SpeakerCache(silence: silence)
        var probs: [[Float]] = []
        var start = 0
        // NeMo の streaming_feat_loader と同じ区切り（左文脈なし）。右文脈は推論にだけ使い、出力はチャンクの分だけ
        while valid > 0 && start < total {
            let end = min(start + Self.chunkLen * Self.subsampling, total)
            let stop = min(end + Self.rightContext * Self.subsampling, total)
            let out = try predict(mel(samples, frames: start..<stop, valid: valid), length: min(valid, stop) - start, cache: cache)
            // チャンクの長さは NeMo と同じく実際の特徴量の長さから求める（diarize_coreml は Core ML の固定長 380 から
            // 求めるため、最後のチャンクが 3.2 秒より短いと末尾の結果がずれる）
            let chunk = cache.update(output: out.preds, chunkEmbs: out.embs, embCount: out.embCount,
                                     chunkCapacity: Self.outputFrames(stop - start) - Self.outputFrames(stop - end))
            probs += stride(from: 0, to: chunk.count, by: SpeakerCache.speakers).map { Array(chunk[$0..<($0 + SpeakerCache.speakers)]) }
            start = end
            progress?(Double(end) / Double(total))
        }
        return DiarizationResult(probs: probs, frameSec: Self.frameSec, turns: Self.turns(probs))
    }

    /// 特徴量フレーム数 → 80 ms フレーム数（切り上げ）
    private static func outputFrames(_ features: Int) -> Int { (features + subsampling - 1) / subsampling }

    /// 1 チャンクを推論する。preds は [話者キャッシュ | FIFO | チャンク] の有効フレームを詰めて並べた発話確率
    private func predict(_ features: [Float], length: Int, cache: SpeakerCache) throws -> (preds: [Float], embs: [Float], embCount: Int) {
        var chunk = [Float](repeating: -99, count: Self.inputFrames * LogMel.bins)  // 余りは NeMo の negative_init_val
        chunk.replaceSubrange(0..<features.count, with: features)
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "chunk": multiArray(chunk, [1, Self.inputFrames, LogMel.bins], .float32),
            "chunk_lengths": multiArray([Int32(length)], [1], .int32),
            "spkcache": multiArray(cache.embs, [1, SpeakerCache.capacity, SpeakerCache.dim], .float32),
            "spkcache_lengths": multiArray([Int32(cache.count)], [1], .int32),
            "fifo": multiArray(cache.fifo, [1, SpeakerCache.fifoCapacity, SpeakerCache.dim], .float32),
            "fifo_lengths": multiArray([Int32(cache.fifoCount)], [1], .int32),
        ])
        let out = try lock.withLock { try model.prediction(from: input) }
        func output(_ name: String) throws -> MLMultiArray {
            guard let value = out.featureValue(for: name)?.multiArrayValue else { throw DiarizationError("Core ML の出力 \(name) がありません") }
            return value
        }
        return (floats(try output("spkcache_fifo_chunk_preds")), floats(try output("chunk_pre_encode_embs")),
                try output("chunk_pre_encode_lengths")[0].intValue)
    }

    /// 発話確率が 0.5 を超える区間（diarize_coreml の後処理と同じ。余白・最小長なし）
    private static func turns(_ probs: [[Float]]) -> [SpeakerTurn] {
        func sec(_ frame: Int) -> Double { (Double(frame) * frameSec * 100).rounded() / 100 }
        var turns: [SpeakerTurn] = []
        for speaker in 0..<SpeakerCache.speakers {
            var onset: Int?
            for t in 0...probs.count {
                let active = t < probs.count && probs[t][speaker] > 0.5
                if active, onset == nil { onset = t }
                if !active, let a = onset {
                    turns.append(SpeakerTurn(start: sec(a), end: sec(t), speaker: speaker))
                    onset = nil
                }
            }
        }
        return turns.sorted { ($0.start, $0.speaker) < ($1.start, $1.speaker) }
    }

    /// .mlmodelc はそのまま使う。.mlpackage はコンパイルして Caches に置き、元のほうが新しくなるまで再利用する
    private static func compiled(_ url: URL) throws -> URL {
        guard url.pathExtension != "mlmodelc" else { return url }
        let fm = FileManager.default
        let cached = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "MinutesKit/\(url.deletingPathExtension().lastPathComponent).mlmodelc")
        func modified(_ url: URL) -> Date? { try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        if let cachedDate = modified(cached), let sourceDate = modified(url), cachedDate >= sourceDate { return cached }
        // Hugging Face のキャッシュの .mlpackage は中のファイルがシンボリックリンクで、Core ML のコンパイラは読めない。
        // 実体を一時フォルダに置き直してからコンパイルする（APFS ではクローンなので容量は使わない）
        let package = fm.temporaryDirectory.appending(path: UUID().uuidString).appending(component: url.lastPathComponent)
        defer { try? fm.removeItem(at: package.deletingLastPathComponent()) }
        for case let file as URL in fm.enumerator(at: url, includingPropertiesForKeys: nil) ?? .init() {
            let source = file.resolvingSymlinksInPath()
            guard (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let target = package.appending(path: String(file.path.dropFirst(url.path.count + 1)))
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: target)
        }
        let temporary = try MLModel.compileModel(at: package)
        try fm.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: cached)
        try fm.moveItem(at: temporary, to: cached)
        return cached
    }
}

// MLMultiArray とのやりとりはメモリをそのまま写す（MLShapedArray を経由すると要素ごとの変換になり、1 チャンクで 100 ms ほどかかる）
private func multiArray<T>(_ values: [T], _ shape: [Int], _ type: MLMultiArrayDataType) throws -> MLMultiArray {
    let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: type)  // 新しく作った配列は詰まった並び
    array.withUnsafeMutableBytes { buffer, _ in values.withUnsafeBytes { buffer.copyMemory(from: $0) } }
    return array
}

private func floats(_ array: MLMultiArray) -> [Float] {
    let shape = array.shape.map(\.intValue)
    let packed = shape.indices.map { shape[($0 + 1)...].reduce(1, *) }
    guard array.dataType == .float32, array.strides.map(\.intValue) == packed else { return MLShapedArray<Float>(converting: array).scalars }
    return array.withUnsafeBufferPointer(ofType: Float.self) { Array($0) }
}
