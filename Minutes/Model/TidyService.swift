import Foundation
import MinutesCore
import Tidying

/// 発言の整形（Gemma 4 E2B のテキスト専用版）の窓口: 「整形する」を押した録音を 1 つずつ整形する。
/// 決まりで片付く発言（大半）を先にまとめて済ませ、モデルの要る発言は画面で見ている所から 1 つずつ整形して、済んだものから画面に出す。
/// 文字起こしの処理中（Whisper を読み込んでいる間）はモデルを外して待つ。整形を終えてしばらくしたらモデルを外す
@MainActor
final class TidyService {
    private let tidier: Tidier
    private var queue: [Recording] = []
    private var worker: Task<Void, Never>?
    /// 整形中の録音と、その整形（止めるときに取り消す）
    private var current: (recording: Recording, job: Task<Void, Error>)?
    private var unloader: Task<Void, Never>?
    /// 文字起こしの処理中か（Library が切り替える）
    var transcribing = false

    init(modelFolder: URL) {
        tidier = Tidier(modelFolder: modelFolder)
    }

    /// 整形を始める（止めた・途中で終えたものは続きから）
    func start(_ r: Recording) {
        guard r.isFinished, current?.recording !== r, !queue.contains(where: { $0 === r }) else { return }
        r.tidyState = .waiting("順番を待っています")
        queue.append(r)
        unloader?.cancel()
        if worker == nil { worker = Task { await runQueue() } }
    }

    /// 整形を止める（済んだ発言はそのまま）
    func stop(_ r: Recording) {
        if let i = queue.firstIndex(where: { $0 === r }) {
            queue.remove(at: i)
            r.tidyState = .stopped
        }
        if current?.recording === r { current?.job.cancel() }
    }

    private func runQueue() async {
        while !queue.isEmpty {
            let r = queue.removeFirst()
            let job = Task { try await tidy(r) }
            current = (r, job)
            do {
                try await job.value
                r.tidyState = nil
            } catch is CancellationError {
                r.tidyState = .stopped
            } catch {
                r.tidyState = .failed(error.localizedDescription)
            }
            r.saveTidied()
            current = nil
        }
        worker = nil
        // 続けて別の録音を整形するときに読み直さないよう、少し待ってからモデルを外す
        unloader = Task { [tidier] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            await tidier.unload()
        }
    }

    private func tidy(_ r: Recording) async throws {
        guard let model = r.model, let transcript = r.transcript else { return }
        let count = model.segments.count
        let texts = (0..<count).map { model.text(ofSegment: $0) }
        let speakers = transcript.segments.map(\.speaker)
        /// 直前の別の話者の発言（問いへの「はい」は省かない）
        let previous: [String?] = (0..<count).map { i in
            guard i > 0, speakers[i - 1] != speakers[i] else { return nil }
            return texts[i - 1]
        }

        // 決まりで片付く発言をまとめて済ませる（メインスレッドの外で）
        let todo = (0..<count).filter { r.tidied[$0] == nil }
        let quick = await Task.detached {
            var out: [Int: TidyOutcome] = [:]
            for i in todo { if let o = Tidier.quick(texts[i], previous: previous[i]) { out[i] = o } }
            return out
        }.value
        r.addTidied(quick)
        r.tidyState = .running
        r.saveTidied()

        // モデルの要る発言を、見ている所から順に 1 つずつ
        var remaining = Set(todo).subtracting(quick.keys)
        var saved = ContinuousClock.now
        while !remaining.isEmpty {
            let focus = (model.blocks.indices.contains(r.tidyFocus) ? model.blocks[r.tidyFocus].words.first : nil).map { model.words[$0].segment } ?? 0
            let i = remaining.filter { $0 >= focus }.min() ?? remaining.min()!
            try await waitForResources(r)
            let outcome = try await tidier.tidy(texts[i], previous: previous[i])
            remaining.remove(i)
            r.addTidied([i: outcome])
            if ContinuousClock.now - saved > .seconds(5) {
                r.saveTidied()
                saved = .now
            }
        }
    }

    /// 文字起こしの処理中は、モデルを外して終わるのを待つ（Whisper と同時にメモリに置かない）
    private func waitForResources(_ r: Recording) async throws {
        while transcribing {
            if await tidier.isLoaded { await tidier.unload() }
            let reason = Recording.TidyState.waiting("文字起こしが終わったら続けます")
            if r.tidyState != reason { r.tidyState = reason }
            try await Task.sleep(for: .seconds(2))
        }
        if r.tidyState != .running { r.tidyState = .running }
    }
}
