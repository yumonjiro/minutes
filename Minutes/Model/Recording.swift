import Foundation
import MinutesCore
import Tidying

/// 1 つの録音。フォルダ（Application Support/Minutes/Recordings/<id>/）に音声と結果を置く:
/// audio.<拡張子>・meta.json（名前など）・transcript.json（文字起こし）・notes.json（ハイライト・ブックマーク・見出し）・
/// tidied.json（発言の整形の結果）
@Observable
final class Recording: Identifiable {
    enum Stage: Equatable {
        case queued, decoding, diarizing(Double), loadingWhisper, transcribing
        case failed(String)
        case interrupted

        var isActive: Bool {
            switch self {
            case .failed, .interrupted: false
            default: true
            }
        }
    }

    /// 画面で変えられる情報（meta.json）
    struct Meta: Codable {
        var title: String
        var created: Date
        var audio: String
        var duration: Double?
        var speakers: Int?
        var names: [String: String] = [:]
    }

    let id: String
    let folder: URL
    var meta: Meta { didSet { save(meta, as: "meta.json") } }
    /// 処理中・失敗・中断のときだけ値がある
    var stage: Stage?
    private(set) var transcript: Transcript?
    /// 重ねた注釈（開いたときに読む。変えるたびに書く）。見出しが増えたり減ったりしたら、見出しの所で吹き出しを分け直す
    private(set) var notes = Notes() {
        didSet {
            if loaded, notes != oldValue { save(notes, as: "notes.json") }
            if let transcript, notes.splits != oldValue.splits { model = TranscriptModel(transcript, splits: notes.splits) }
        }
    }
    /// 画面用に組み立て直した文字起こし（発言のまとまり・話者の色など）
    private(set) var model: TranscriptModel?
    private(set) var loaded = false

    /// 発言の整形の状態（「整形する」を押してから終わるまで。止めた・失敗したときはそのまま残す）
    enum TidyState: Equatable {
        /// 順番を待っている（理由）
        case waiting(String)
        case running
        case stopped
        case failed(String)
    }

    /// 発言の整形の結果（文字起こしの発言の番号 → 結果）
    private(set) var tidied: [Int: TidyOutcome] = [:]
    var tidyState: TidyState?
    /// 画面で見ている所（吹き出しの番号）。整形はここから進める（一覧を送るたびに変わるので、画面の更新には使わない）
    @ObservationIgnored var tidyFocus = 0
    @ObservationIgnored private var tidiedCache: (model: UUID, count: Int, value: TidiedTranscript)?

    init(id: String, folder: URL, meta: Meta) {
        self.id = id
        self.folder = folder
        self.meta = meta
    }

    var title: String { meta.title }
    var audioURL: URL { folder.appending(component: meta.audio) }
    var isProcessing: Bool { stage?.isActive ?? false }
    var isFinished: Bool { transcript?.progress.final == true && !isProcessing }

    /// 画面に出す話者名（名前を付けていなければ「話者A」など）
    func name(of speaker: String) -> String {
        meta.names[speaker] ?? model?.labels[speaker] ?? speaker
    }

    func rename(speaker: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        meta.names[speaker] = name
    }

    // MARK: - 注釈

    /// 語の範囲（最初の語の始まりから最後の語の終わりまで、秒）にハイライトを付ける
    @discardableResult
    func addHighlight(from: Double, to: Double, color: Int, comment: String = "") -> UUID {
        let a = Annotation(kind: .highlight, from: from, to: to, color: color, text: comment)
        notes.items.append(a)
        return a.id
    }

    /// 始まりが time の発言のブックマークを付け外しする
    func toggleBookmark(at time: Double) {
        if let i = notes.items.firstIndex(where: { $0.kind == .bookmark && abs($0.from - time) < 0.05 }) {
            notes.items.remove(at: i)
        } else {
            notes.items.append(Annotation(kind: .bookmark, from: time, to: time))
        }
    }

    /// 始まりが time の発言の前に見出しを入れる
    @discardableResult
    func addHeading(at time: Double, level: Int, title: String) -> UUID {
        let a = Annotation(kind: .heading, from: time, to: time, level: level, text: title)
        notes.items.append(a)
        return a.id
    }

    func annotation(_ id: UUID) -> Annotation? { notes.items.first { $0.id == id } }

    func updateAnnotation(_ id: UUID, _ change: (inout Annotation) -> Void) {
        guard let i = notes.items.firstIndex(where: { $0.id == id }) else { return }
        change(&notes.items[i])
    }

    func removeAnnotation(_ id: UUID) {
        notes.items.removeAll { $0.id == id }
    }

    // MARK: - 発言の整形

    /// 整形した表示用のデータ（整形の結果が増えるたびに作り直す）
    var tidiedTranscript: TidiedTranscript? {
        guard let model else { return nil }
        if let c = tidiedCache, c.model == model.id, c.count == tidied.count { return c.value }
        let value = TidiedTranscript(model: model, outcomes: tidied)
        tidiedCache = (model.id, tidied.count, value)
        return value
    }

    /// 整形を済ませた発言の数と、発言の数
    var tidyProgress: (done: Int, total: Int) { (tidied.count, transcript?.segments.count ?? 0) }

    func addTidied(_ outcomes: [Int: TidyOutcome]) {
        guard !outcomes.isEmpty else { return }
        tidied.merge(outcomes) { $1 }
    }

    /// 整形の結果を tidied.json に書く（発言の番号と本文を添え、文字起こしが変わったら読み込まないようにする）
    func saveTidied() {
        guard let transcript else { return }
        let entries = tidied.keys.sorted().compactMap { i in
            transcript.segments.indices.contains(i) ? TidyFile.Entry(index: i, text: transcript.segments[i].text, result: tidied[i]!) : nil
        }
        save(TidyFile(version: Tidier.version, segments: entries), as: "tidied.json")
    }

    /// 文字起こしをやり直すときは、整形の結果も捨てる
    func clearTidied() {
        tidied = [:]
        tidyState = nil
        try? FileManager.default.removeItem(at: file("tidied.json"))
    }

    private func loadTidied() {
        guard let transcript, let data = try? Data(contentsOf: file("tidied.json")),
              let f = try? JSONDecoder.library.decode(TidyFile.self, from: data), f.version == Tidier.version else { return }
        var outcomes: [Int: TidyOutcome] = [:]
        for e in f.segments where transcript.segments.indices.contains(e.index) && transcript.segments[e.index].text == e.text {
            outcomes[e.index] = e.result
        }
        tidied = outcomes
        // 途中で止めた（アプリを終えた）ものは、続きから整形できるようにしておく
        if !outcomes.isEmpty, outcomes.count < transcript.segments.count { tidyState = .stopped }
    }

    private struct TidyFile: Codable {
        /// 整形の版（Tidier.version）
        var version: Int
        struct Entry: Codable {
            var index: Int
            var text: String
            var result: TidyOutcome
        }

        var segments: [Entry]
    }

    // MARK: - 読み書き

    /// 文字起こしと注釈を読む（一覧を出すときには読まず、開いたときに読む）
    func loadIfNeeded() {
        guard !loaded else { return }
        if let data = try? Data(contentsOf: file("notes.json")), let n = try? JSONDecoder.library.decode(Notes.self, from: data) {
            notes = n
        }
        loaded = true
        if let data = try? Data(contentsOf: file("transcript.json")), let t = try? Transcript(jsonData: data) {
            setTranscript(t, save: false)
            loadTidied()
        }
    }

    func setTranscript(_ t: Transcript, save: Bool = true) {
        transcript = t
        model = TranscriptModel(t, splits: notes.splits)
        if save, let data = try? t.jsonData() {
            try? data.write(to: file("transcript.json"), options: .atomic)
        }
        // 処理が終わったら一覧用の長さと話者数を覚える（変わったときだけ書き込む）
        if t.progress.final, meta.duration != t.progress.totalSec || meta.speakers != model?.speakers.count {
            var m = meta
            m.duration = t.progress.totalSec
            m.speakers = model?.speakers.count
            meta = m
        }
    }

    /// 録音の処理が済んでいるか（前回の起動で途中のまま終わっていないか）を、transcript.json を読んで確かめる
    func checkFinished() -> Bool {
        guard let data = try? Data(contentsOf: file("transcript.json")),
              let t = try? JSONDecoder().decode(ProgressOnly.self, from: data) else { return false }
        return t.progress.final
    }

    private struct ProgressOnly: Decodable {
        var progress: Transcript.Progress
    }

    func file(_ name: String) -> URL { folder.appending(component: name) }

    private func save<T: Encodable>(_ value: T, as name: String) {
        if let data = try? JSONEncoder.library.encode(value) {
            try? data.write(to: file(name), options: .atomic)
        }
    }
}

extension JSONEncoder {
    static let library: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let library: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
