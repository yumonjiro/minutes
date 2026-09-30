// 結果のデータ（録音ごとの transcript.json）。

import Foundation

public struct Transcript: Codable, Sendable, Equatable {
    /// 音声ファイルの名前
    public var audio: String
    public var label: String
    public var asr: String
    /// 発言（話者の交代・文末・長い無音で区切った単位）
    public var segments: [Segment]
    /// 話者分離の区間
    public var diarization: [Turn]
    public var frameSec: Double
    /// 話者ごとの発話確率（frameSec ごと、小数 2 桁）。どこかで 0.5 以上になった話者だけ
    public var speakerProbs: [String: [Float]]
    public var progress: Progress
    public var timingsSec: Timings

    public struct Segment: Codable, Sendable, Equatable, Identifiable {
        public var id: Int
        public var start: Double
        public var end: Double
        public var text: String
        public var speaker: String
        /// 話者の決め方（Whisper の区間ごとに、発話確率が最大の話者）
        public var method = "segment_prob"
        /// 発言と重なる話者分離の区間の長さ（秒）
        public var overlapBySpeaker: [String: Double]
        /// 発言の間の平均の発話確率（最大が 0.1 以上の話者）
        public var probBySpeaker: [String: Double]
        /// 時間の重なりだけで決めた場合の話者（WhisperX と同じ決め方。比べる用）
        public var speakerByOverlap: String?
        /// 再生に合わせたハイライト用の語（句読点付き。Whisper の区間の切れ目に句読点が無ければ先頭に空白）
        public var words: [Word]

        enum CodingKeys: String, CodingKey {
            case id, start, end, text, speaker, method, words
            case overlapBySpeaker = "overlap_by_speaker", probBySpeaker = "prob_by_speaker"
            case speakerByOverlap = "speaker_by_overlap"
        }
    }

    public struct Word: Codable, Sendable, Equatable {
        public var w: String
        public var s: Double
        public var e: Double
    }

    public struct Turn: Codable, Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var speaker: String
    }

    public struct Progress: Codable, Sendable, Equatable {
        public var doneSec: Double
        public var totalSec: Double
        /// false の間は途中結果（区切りごとに発言が増える）
        public var final: Bool
        /// 文字起こしを終えた区切り [開始, 終了]
        public var chunks: [[Double]]

        enum CodingKeys: String, CodingKey {
            case doneSec = "done_sec", totalSec = "total_sec", final, chunks
        }
    }

    public struct Timings: Codable, Sendable, Equatable {
        public var diarize: Double?
        /// 文字起こしを始めてからの秒（モデルの読み込みを含む）
        public var transcribe: Double?
        /// 文字起こしを始めてから最初の区切りの結果が出るまでの秒
        public var firstResult: Double?

        enum CodingKeys: String, CodingKey {
            case diarize, transcribe, firstResult = "first_result"
        }
    }

    enum CodingKeys: String, CodingKey {
        case audio, label, asr, segments, diarization, progress
        case frameSec = "frame_sec", speakerProbs = "speaker_probs", timingsSec = "timings_sec"
    }
}

extension Transcript {
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public init(jsonData: Data) throws {
        self = try JSONDecoder().decode(Transcript.self, from: jsonData)
    }
}
