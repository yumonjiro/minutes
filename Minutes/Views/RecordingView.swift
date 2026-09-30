import MinutesCore
import SwiftUI
import UniformTypeIdentifiers

/// 1 つの録音の画面: ツールバー（タイトル・表示の仕方・検索・書き出し・右のパネル）、中央に文字起こし、下に再生バー、右に目次と注釈のパネル。
/// 表示の仕方は原文・整形（つなぎ言葉と相槌を取り除いた表示）・見比べ。再生バーのボタンで、タイムライン（下）と
/// 没入モード（中央の文字起こしを大きく、今の発言を前に。前後の発言は薄く）をそれぞれ切り替える
struct RecordingView: View {
    @Environment(Library.self) private var library
    @Bindable var recording: Recording
    @State private var player = AudioPlayer()
    @State private var timeline = false
    @State private var search = ""
    @State private var searching = false
    @State private var hitIndex: Int?
    @State private var filter: String?
    @State private var exporting = false
    @State private var controller = TranscriptController()
    /// 右のパネルを開いているか（前回の開き具合は、画面が出てから戻す。最初から開いた状態で渡すと出ないため）
    @State private var showNotes = false
    @AppStorage("notesPanel.open") private var notesOpen = false
    @AppStorage("transcript.mode") private var mode = TranscriptMode.original
    @AppStorage("transcript.immersive") private var immersive = false
    @AppStorage(TextSize.normalKey) private var textStep = TextSize.defaultStep
    @AppStorage(TextSize.immersiveKey) private var immersiveTextStep = TextSize.defaultStep
    @FocusState private var focused: Bool

    var body: some View {
        let model = recording.model
        let hits = model.map { $0.search(search) } ?? []
        VStack(spacing: 0) {
            if case .failed(let message)? = recording.stage {
                FailureBanner(text: message) { library.retry(recording) }
            } else if recording.stage == .interrupted {
                FailureBanner(text: "処理が途中で止まりました（アプリの終了など）") { library.retry(recording) }
            }
            Group {
                if let model, !model.blocks.isEmpty {
                    if mode != .original, recording.tidied.isEmpty, recording.tidyState == nil {
                        TidyIntro(processing: !recording.isFinished) { library.tidy.start(recording) }
                    } else {
                        VStack(spacing: 0) {
                            if mode != .original {
                                TidyBar(recording: recording, tidy: library.tidy,
                                        width: mode == .compare ? TranscriptMetrics.compareColumn : TranscriptMetrics.column)
                            }
                            TranscriptView(model: model, recording: recording, player: player, controller: controller, mode: mode,
                                           immersive: immersive,
                                           textSize: TextSize.size(step: immersive ? immersiveTextStep : textStep, immersive: immersive), filter: $filter,
                                           hits: Set(hits.flatMap { $0 }), activeHit: hitIndex.flatMap { hits.indices.contains($0) ? hits[$0] : nil })
                        }
                    }
                } else {
                    StageView(stage: recording.stage, loaded: recording.loaded)
                }
            }
            .frame(maxHeight: .infinity)

            if let model, !model.blocks.isEmpty {
                PlayerBar(player: player, model: model, recording: recording, expanded: $timeline, immersive: $immersive)
                    .padding(.horizontal, 24)
                    .padding(.top, 6)
                    .padding(.bottom, 16)
            }
        }
        .inspector(isPresented: $showNotes) {
            Group {
                if let model {
                    NotesPanel(model: model, recording: recording, player: player, controller: controller)
                } else {
                    Color.clear
                }
            }
            .inspectorColumnWidth(min: 250, ideal: 300, max: 440)
        }
        .navigationTitle(recording.title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar(hits: hits) }
        .focusedSceneValue(\.transcriptController, controller)
        .onChange(of: showNotes) { notesOpen = showNotes }
        .searchable(text: $search, isPresented: $searching, placement: .toolbar, prompt: "文字起こしを検索")
        .onSubmit(of: .search) { if !hits.isEmpty { hitIndex = ((hitIndex ?? -1) + 1) % hits.count } }
        .onChange(of: search) { hitIndex = nil }
        .fileExporter(isPresented: $exporting, document: exporting ? TextDocument(text: exportText()) : nil, contentType: .markdownText,
                      defaultFilename: "\(recording.title)_文字起こし.md") { _ in }
        .task(id: recording.id) {
            recording.loadIfNeeded()
            player.load(recording.audioURL)
            controller.player = player
            controller.recording = recording
            showNotes = notesOpen
            focused = true  // 一覧で選んだ直後から Space・←→ で操作できるように
            #if DEBUG
            if Debug.timeline { timeline = true }
            if let v = Debug.env["MINUTES_IMMERSIVE"] { immersive = v == "1" }
            if let v = Debug.env["MINUTES_TEXTSIZE"].flatMap(Int.init) { if immersive { immersiveTextStep = v } else { textStep = v } }
            // 表示の切り替えを、起動の後の決まった時刻に行う（止まっているときの切り替え・素早い切り替えを確かめる）
            for item in (Debug.env["MINUTES_SCHEDULE"] ?? "").split(separator: ",") {
                let p = item.split(separator: ":")
                guard p.count == 2, let t = Double(p[0]) else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                    if p[1] == "i" { immersive.toggle() } else if let s = Int(p[1]) { if immersive { immersiveTextStep = s } else { textStep = s } }
                }
            }
            if let m = Debug.env["MINUTES_MODE"].flatMap(TranscriptMode.init) { mode = m }
            if Debug.env["MINUTES_TIDY"] == "1" { library.tidy.start(recording) }
            if let tab = Debug.env["MINUTES_NOTES"] {
                UserDefaults.standard.set(tab, forKey: "notesPanel.tab")
                showNotes = true
            }
            if let q = Debug.search {
                search = q
                hitIndex = 0
            }
            if Debug.perf == "play" {
                player.model = recording.model
                player.mute()
                player.seek(to: Debug.seek ?? 140, play: true)
            } else if let t = Debug.seek {
                player.model = recording.model
                player.seek(to: t)
            }
            #endif
        }
        .onChange(of: recording.model?.id) { player.model = recording.model }
        .onAppear { player.model = recording.model }
        .onDisappear { player.stop() }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.space) { player.toggle(); return .handled }
        .onKeyPress(.leftArrow) { player.skip(-5); return .handled }
        .onKeyPress(.rightArrow) { player.skip(5); return .handled }
        .onKeyPress("b") {
            // 今の発言（発言の合間なら直前の発言）をブックマーク
            guard let b = player.shownBlock, let model else { return .ignored }
            recording.apply(.bookmark(block: b), model: model)
            return .handled
        }

    }

    private var subtitle: String {
        var parts: [String] = []
        if let d = recording.meta.duration ?? recording.transcript?.progress.totalSec, d > 0 { parts.append(formatDuration(d)) }
        if let n = recording.model?.speakers.count, n > 0 { parts.append("話者 \(n) 人") }
        return parts.joined(separator: "・")
    }

    @ToolbarContentBuilder
    private func toolbar(hits: [[Int]]) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("表示", selection: $mode) {
                Text("原文").tag(TranscriptMode.original)
                Text("整形").tag(TranscriptMode.tidied)
                Text("見比べ").tag(TranscriptMode.compare)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("原文・整形（つなぎ言葉や相槌を取り除いた表示）・見比べ（左に原文、右に整形）")
            .disabled(recording.model == nil)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if !search.isEmpty && recording.model != nil {
                Text(hits.isEmpty ? "0 件" : "\(hitIndex.map { "\($0 + 1)" } ?? "-") / \(hits.count)")
                    .monospacedDigit().foregroundStyle(.secondary).font(.callout)
                ControlGroup {
                    Button("前へ", systemImage: "chevron.up") { if !hits.isEmpty { hitIndex = ((hitIndex ?? 0) - 1 + hits.count) % hits.count } }
                    Button("次へ", systemImage: "chevron.down") { if !hits.isEmpty { hitIndex = ((hitIndex ?? -1) + 1) % hits.count } }
                }
                .disabled(hits.isEmpty)
            }
            Button("書き出す", systemImage: "square.and.arrow.down") { exporting = true }
                .help("Markdown で書き出す（見出し・ハイライト・コメント・ブックマーク付き）")
                .disabled(recording.model == nil)
            Button("目次と注釈", systemImage: "sidebar.right") { showNotes.toggle() }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .help(showNotes ? "目次と注釈を隠す（⌥⌘0）" : "目次と注釈を表示（⌥⌘0）")
        }
    }

    /// 書き出す文字（Markdown）: 見出しは ## と ###、発言は「**[時刻] 名前**」（ブックマークは ★）と本文、
    /// ハイライトは ==…== で囲み、発言の後に「> 【色の名前】ハイライトした所 — コメント」。
    /// 整形した表示（整形・見比べ）のときは整形後の本文で書き出す（省いた発言は除く）
    private func exportText() -> String {
        guard let model = recording.model else { return "" }
        let notes = model.resolve(recording.notes), headings = Dictionary(grouping: notes.headings, by: \.block)
        let tidied = mode == .original ? nil : recording.tidiedTranscript
        /// 語 w の本文（整形後なら、消した語は空）
        func text(_ w: Int) -> String {
            let b = model.words[w].block
            guard let t = tidied?.blocks[b] else { return model.words[w].text }
            return (t.text as NSString).substring(with: t.words[w - model.blocks[b].words.lowerBound])
        }
        var lines = ["# \(recording.title)", ""]
        for b in model.blocks {
            for h in headings[b.id] ?? [] { lines += [(h.level == 1 ? "## " : "### ") + (h.title.isEmpty ? "無題の見出し" : h.title), ""] }
            if tidied?.blocks[b.id].state == .dropped { continue }
            lines.append("**[\(formatTime(b.start))] \(recording.name(of: b.speaker))**" + (notes.bookmarks[b.id] != nil ? " ★" : ""))
            let marks = notes.highlights(in: b.words)
            var body = "", inside = false
            for w in b.words {
                let covered = marks.contains { $0.words.contains(w) }
                if covered != inside {
                    body += "=="
                    inside = covered
                }
                body += text(w)
            }
            lines.append(body + (inside ? "==" : ""))
            for h in marks where b.words.contains(h.words.lowerBound) {
                lines.append("> 【\(HighlightColor.name(h.color))】\(h.words.map(text).joined())" + (h.comment.isEmpty ? "" : " — \(h.comment)"))
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

extension UTType {
    nonisolated static let markdownText = UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
}

extension FocusedValues {
    /// 前に出ている録音の画面の操作の窓口（メニューの「移動」から使う）
    @Entry var transcriptController: TranscriptController?
}

/// 書き出し用のテキストファイル
struct TextDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    static let writableContentTypes: [UTType] = [.markdownText, .plainText]
    var text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = "" }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// 最初の発言が届くまでの表示（くるくる＋今の段階）
private struct StageView: View {
    let stage: Recording.Stage?
    let loaded: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let texts {
                if stage?.isActive == true {
                    ProgressView().controlSize(.large).padding(.bottom, 18)
                }
                Text(texts.title).font(.system(size: 16, weight: .semibold))
                if !texts.detail.isEmpty {
                    Text(texts.detail).font(.callout).foregroundStyle(.secondary).padding(.top, 4)
                }
                if case .diarizing(let p)? = stage, p > 0 {
                    ProgressView(value: p).frame(width: 220).padding(.top, 14)
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .multilineTextAlignment(.center)
    }

    private var texts: (title: String, detail: String)? {
        switch stage {
        case .queued: ("順番を待っています", "前の録音の処理が終わると始まります")
        case .decoding: ("音声を読み込み中…", "")
        case .diarizing: ("話者分離中…", "誰がいつ話したかを聞き分けています")
        case .loadingWhisper: ("文字起こしの準備中…", "音声認識モデルを読み込んでいます")
        case .transcribing: ("文字起こしを作成中…", "最初の発言がまもなく表示されます")
        case .failed, .interrupted: ("文字起こしがありません", "上の「もう一度処理する」で処理し直せます")
        case nil: loaded ? ("発言がありません", "") : nil
        }
    }
}

private struct FailureBanner: View {
    let text: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(text).lineLimit(2)
            Spacer()
            Button("もう一度処理する", systemImage: "arrow.clockwise", action: retry)
                .buttonStyle(.bordered)
        }
        .font(.callout)
        .foregroundStyle(.red)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }
}
