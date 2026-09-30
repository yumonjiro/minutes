import Foundation
import MinutesCore
import ModelStore
import UniformTypeIdentifiers

/// 録音の一覧と、録音の処理（話者分離 → 文字起こし）・発言の整形の窓口。
/// モデルは ModelStore が初回に取得したものを使い、処理はすべてこの Mac の中で行う
@Observable
final class Library {
    static let audioTypes: [UTType] = [.audio, .mpeg4Movie, .quickTimeMovie]

    private(set) var recordings: [Recording] = []  // 新しい順
    /// 「録音を追加」のファイル選択を出す（メニューの ⌘O からも開く）
    var isImporting = false
    /// 画面で開いてほしい録音（Finder から開いたファイルなど）
    var focus: String?

    let processor: MeetingProcessor
    let tidy: TidyService
    private let root: URL
    private var queue: [Recording] = []
    private var worker: Task<Void, Never>?

    init(models: ModelStore) {
        let support = URL.applicationSupportDirectory.appending(component: "Minutes")
        root = support.appending(component: "Recordings")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        processor = MeetingProcessor(models: .init(
            diarizer: models.paths.diarizer, silenceEmbedding: models.paths.silenceEmbedding, whisper: models.paths.whisper,
            whisperName: models.whisper.name))
        tidy = TidyService(modelFolder: models.paths.tidier)
        load()
    }

    /// 文字起こしのモデルを替える（設定で選び直し、そのモデルがそろったとき）。処理中の録音はそのまま終える
    func useWhisper(_ models: ModelStore) {
        let processor = processor
        Task { await processor.useWhisper(models.paths.whisper, name: models.whisper.name) }
    }

    func recording(_ id: String) -> Recording? { recordings.first { $0.id == id } }

    private func load() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        recordings = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appending(component: "meta.json")),
                  let meta = try? JSONDecoder.library.decode(Recording.Meta.self, from: data) else { return nil }
            let r = Recording(id: dir.lastPathComponent, folder: dir, meta: meta)
            if meta.duration == nil && !r.checkFinished() { r.stage = .interrupted }  // 前回の起動で処理が終わらなかった
            return r
        }
        .sorted { $0.meta.created > $1.meta.created }
    }

    // MARK: - 追加・削除

    /// 音声ファイルを録音として追加し、処理を予約する。追加した録音を返す（最初のもの）
    @discardableResult
    func add(_ urls: [URL]) -> Recording? {
        var added: [Recording] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let id = UUID().uuidString
            let folder = root.appending(component: id)
            let audio = "audio." + (url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased())
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: folder.appending(component: audio))
            } catch {
                try? FileManager.default.removeItem(at: folder)
                continue
            }
            let r = Recording(id: id, folder: folder,
                              meta: .init(title: url.deletingPathExtension().lastPathComponent, created: .now, audio: audio))
            r.loadIfNeeded()
            added.append(r)
        }
        recordings.insert(contentsOf: added.reversed(), at: 0)
        added.forEach(enqueue)
        return added.first
    }

    func delete(_ r: Recording) {
        tidy.stop(r)
        queue.removeAll { $0 === r }
        recordings.removeAll { $0 === r }
        try? FileManager.default.removeItem(at: r.folder)
    }

    func retry(_ r: Recording) { enqueue(r) }

    // MARK: - 録音の処理（1 件ずつ順に）

    private func enqueue(_ r: Recording) {
        tidy.stop(r)
        r.clearTidied()  // 文字起こしが変わるので、整形はやり直す
        r.stage = .queued
        queue.append(r)
        if worker == nil {
            worker = Task { await runQueue() }
        }
    }

    /// 文字起こしの間は発言の整形を止める（Whisper と Gemma を同時にメモリに置かない）
    private func runQueue() async {
        tidy.transcribing = true
        while !queue.isEmpty {
            let r = queue.removeFirst()
            guard recordings.contains(where: { $0 === r }) else { continue }
            await process(r)
        }
        worker = nil
        await processor.unloadWhisper()  // 処理が済んだらメモリを空ける（次の録音で読み直す）
        tidy.transcribing = false
    }

    private func process(_ r: Recording) async {
        do {
            for try await event in await processor.process(audio: r.audioURL) {
                guard recordings.contains(where: { $0 === r }) else { return }  // 処理中に削除された
                switch event {
                case .stage(.decoding): r.stage = .decoding
                case .stage(.diarizing): r.stage = .diarizing(0)
                case .stage(.loadingWhisper): r.stage = .loadingWhisper
                case .stage(.transcribing): r.stage = .transcribing
                case .diarizing(let p): r.stage = .diarizing(p)
                case .partial(let t): r.setTranscript(t)
                case .finished(let t):
                    r.setTranscript(t)
                    r.stage = nil
                }
            }
        } catch {
            r.stage = .failed(error.localizedDescription)
        }
    }
}
