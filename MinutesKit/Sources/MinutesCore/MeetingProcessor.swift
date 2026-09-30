// 録音の処理の流れ: 音声の読み込み → 話者分離 → 無音で区切りながら文字起こしと話者の割り当て。
// 区切りごとに途中結果を流す（アプリは終わった分から発言を表示できる）。
// Whisper の計算が失敗したら（メモリが足りないときなど）、その録音の処理を失敗にする（アプリは落ちず、もう一度処理できる）

import Diarization
import Foundation
import Transcription

public actor MeetingProcessor {
    /// モデルの置き場所
    public struct Models: Sendable {
        /// Nemotron-3-Diarization（.mlmodelc か .mlpackage）
        public var diarizer: URL
        /// 話者キャッシュの無音の埋め込み（learnable_sil_emb.f32）
        public var silenceEmbedding: URL
        /// Whisper（openai/whisper-large-v3 などの重み・設定・トークナイザーのあるフォルダ）
        public var whisper: URL
        /// 結果に書く Whisper のモデルの名前（「Whisper large-v3-turbo」など）
        public var whisperName: String

        public init(diarizer: URL, silenceEmbedding: URL, whisper: URL, whisperName: String) {
            self.diarizer = diarizer
            self.silenceEmbedding = silenceEmbedding
            self.whisper = whisper
            self.whisperName = whisperName
        }
    }

    public enum Stage: Sendable {
        case decoding, diarizing
        /// Whisper の読み込みを待っている（話者分離と並行して読み込むので、たいていは待たない）
        case loadingWhisper
        case transcribing
    }

    public enum Event: Sendable {
        case stage(Stage)
        /// 話者分離の進み具合（0〜1）
        case diarizing(Double)
        /// 区切りごとの途中結果（progress.final は false）
        case partial(Transcript)
        case finished(Transcript)
    }

    private static let sampleRate = 16000.0

    private var models: Models
    private var whisper: WhisperTranscriber
    private var queue: Task<Void, Never>?  // 処理は 1 件ずつ（Whisper を同時に使わない）

    public init(models: Models) {
        self.models = models
        whisper = WhisperTranscriber(folder: models.whisper)
    }

    /// 音声ファイルを処理する。処理中に呼ぶと前の処理の後に行う。ストリームを途中でやめる（読んでいる Task を取り消す）と処理も止まる
    public func process(audio: URL) -> AsyncThrowingStream<Event, Error> {
        let (stream, events) = AsyncThrowingStream.makeStream(of: Event.self)
        let previous = queue
        let job = Task {
            await previous?.value
            do {
                try await run(audio: audio, events: events)
                events.finish()
            } catch {
                events.finish(throwing: error)
            }
        }
        queue = job
        events.onTermination = { _ in job.cancel() }
        return stream
    }

    /// 文字起こしのモデルを替える（設定で選び直したとき）。処理中ならその後で替える
    public func useWhisper(_ folder: URL, name: String) async {
        let previous = queue
        let job = Task {
            await previous?.value
            await replaceWhisper(folder, name: name)
        }
        queue = job
        await job.value
    }

    private func replaceWhisper(_ folder: URL, name: String) async {
        await whisper.unload()
        whisper = WhisperTranscriber(folder: folder)
        models.whisper = folder
        models.whisperName = name
    }

    /// Whisper を外してメモリを空ける（整形のモデルを使う前など）。処理中ならその後で外す。次の処理で読み直す
    public func unloadWhisper() async {
        let previous = queue
        let job = Task {
            await previous?.value
            await self.whisper.unload()  // 外す時点のモデル（途中で替えていれば新しいほう）
        }
        queue = job
        await job.value
    }

    private func run(audio: URL, events: AsyncThrowingStream<Event, Error>.Continuation) async throws {
        try Task.checkCancellation()
        events.yield(.stage(.decoding))
        let samples = try decodeAudio16kMono(url: audio)
        let total = Double(samples.count) / Self.sampleRate
        // 話者分離と並行して読み込む
        async let whisperReady: Void = whisper.load()

        events.yield(.stage(.diarizing))
        let diarizeStart = ContinuousClock.now
        let diarization = try NemotronDiarizer(modelURL: models.diarizer, silenceEmbeddingURL: models.silenceEmbedding)
            .diarize(samples) { events.yield(.diarizing($0)) }
        let diarizeSec = seconds(since: diarizeStart)
        try Task.checkCancellation()

        let timeline = SpeakerTimeline(diarization)
        var transcript = Transcript(audio: audio.lastPathComponent, asr: "\(models.whisperName)（MLX）", timeline: timeline, totalSec: total)
        transcript.timingsSec.diarize = diarizeSec
        if await !whisper.isLoaded { events.yield(.stage(.loadingWhisper)) }
        let start = ContinuousClock.now
        try await whisperReady
        events.yield(.stage(.transcribing))

        let plan = chunks(silences: silenceCenters(probs: diarization.probs, frameSec: diarization.frameSec), total: total)
        var whisperSegments = 0
        for (n, chunk) in plan.enumerated() {
            try Task.checkCancellation()
            let piece = Array(samples[Int(chunk.start * Self.sampleRate)..<min(Int(chunk.end * Self.sampleRate), samples.count)])
            let segments = try await whisper.transcribe(piece)
            let words = timeline.assign(segments, offset: chunk.start, firstSeg: whisperSegments)
            whisperSegments += segments.count
            transcript.segments += timeline.utterances(words, firstID: transcript.segments.count)
            transcript.progress.chunks.append([round2(chunk.start), round2(chunk.end)])
            transcript.progress.doneSec = round2(chunk.end)
            transcript.progress.final = n == plan.count - 1
            transcript.timingsSec.transcribe = seconds(since: start)
            if n == 0 { transcript.timingsSec.firstResult = transcript.timingsSec.transcribe }
            events.yield(transcript.progress.final ? .finished(transcript) : .partial(transcript))
        }
        if plan.isEmpty {
            transcript.progress.final = true
            events.yield(.finished(transcript))
        }
    }
}

extension Transcript {
    /// 発言がまだ無い結果
    init(audio: String, asr: String, timeline: SpeakerTimeline, totalSec: Double) {
        var probs: [String: [Float]] = [:]
        for i in 0..<(timeline.probs.first?.count ?? 0) where timeline.probs.contains(where: { $0[i] >= 0.5 }) {
            probs[speakerName(i)] = timeline.probs.map { ($0[i] * 100).rounded() / 100 }
        }
        self.init(
            audio: audio, label: "Nemotron-3-Diarization + \(asr)（文ごとに割り当て）",
            asr: asr, segments: [], diarization: timeline.turns, frameSec: timeline.frameSec,
            speakerProbs: probs, progress: Progress(doneSec: 0, totalSec: round2(totalSec), final: false, chunks: []),
            timingsSec: Timings())
    }
}

private func seconds(since start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return ((Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18) * 10).rounded() / 10
}
