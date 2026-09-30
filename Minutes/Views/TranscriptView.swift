import AppKit
import MinutesCore
import SwiftUI

/// 文字起こし: 発言ごとに「時刻・アイコン・話者名」の行と、その下に字下げした発言を並べる（行も文字も自分で描く TranscriptListView）。
/// 再生中の発言と語、ポインタの下の発言と語、選択、検索の一致、注釈（見出し・ハイライト・コメント・ブックマーク）を描く。
/// クリックで再生、ドラッグで選択。選択のすぐ上のバーでハイライト・コメント・見出し・コピー。
/// 整形した表示では本文を整形後に替え（省いた発言は並べない）、見比べでは左に原文（取り除いた所に線）、右に整形後を並べる
struct TranscriptView: View {
    let model: TranscriptModel
    let recording: Recording
    let player: AudioPlayer
    let controller: TranscriptController
    let mode: TranscriptMode
    /// 没入モード（今の発言を大きく、前後の発言を薄く。見比べは整形後だけにする）
    let immersive: Bool
    /// 本文の文字の大きさ（pt）
    let textSize: CGFloat
    @Binding var filter: String?
    let hits: Set<Int>
    let activeHit: [Int]?
    @State private var following = true
    @State private var recall = 0

    var body: some View {
        let notes = model.resolve(recording.notes)
        let headings = Dictionary(grouping: notes.headings, by: \.block)
        let tidied = mode == .original ? nil : recording.tidiedTranscript, compare = mode == .compare && !immersive
        TranscriptListRepresentable(
            document: TranscriptDocument(
                blocks: model.blocks.map { b in
                    var block = TranscriptDocument.Block(speaker: b.speaker, name: recording.name(of: b.speaker), start: b.start, words: b.words,
                                                         headings: headings[b.id] ?? [], text: model.text(of: b), ranges: model.ranges(of: b))
                    if let t = tidied?.blocks[b.id] {
                        if compare { block.original = .init(text: block.text, ranges: block.ranges, removed: t.removed) }
                        block.text = t.text
                        block.ranges = t.words
                        block.pending = t.state == .pending
                        block.note = t.note
                        block.hidden = !compare && t.state == .dropped && block.headings.isEmpty
                    }
                    return block
                },
                words: model.words, colors: model.nsColors, live: recording.isProcessing ? liveNote : nil, compare: compare, immersive: immersive,
                textSize: textSize),
            highlights: notes.highlights, bookmarks: notes.bookmarks,
            player: player, filter: filter, hits: hits, activeHit: activeHit, following: following, recall: recall, controller: controller,
            events: .init(
                userScrolled: { if player.isPlaying { following = false } },
                rename: { recording.rename(speaker: $0, to: $1) },
                filter: { filter = $0 },
                edit: { recording.apply($0, model: model) },
                visible: { recording.tidyFocus = $0 }))
        .overlay(alignment: .bottom) {
            if !following && player.isPlaying {
                Button("再生位置に戻る") {
                    following = true
                    recall += 1
                }
                .buttonStyle(FloatingButtonStyle())
                .padding(.bottom, 14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.2), value: following)
        .onChange(of: player.isPlaying) { if player.isPlaying { following = true } }
    }

    private var liveNote: String {
        let doing = "文字起こしを作成中…"
        guard let p = recording.transcript?.progress, p.totalSec > 0 else { return doing }
        return "\(doing)  \(formatTime(p.doneSec)) / \(formatTime(p.totalSec))"
    }
}

/// 本文の文字の大きさの段階（「表示」メニューの ⌘+・⌘−・⌘0）。通常と没入モードで別々に覚える
enum TextSize {
    static let normal: [CGFloat] = [12, 13, 14, 15, 17, 19, 21, 24]
    static let immersive: [CGFloat] = [16, 18, 20, 22, 25, 28, 32, 36]
    static let defaultStep = 3
    /// 保存する名前（通常・没入モード）
    static let normalKey = "transcript.textSize", immersiveKey = "transcript.immersiveTextSize"

    static func sizes(immersive: Bool) -> [CGFloat] { immersive ? Self.immersive : normal }

    static func size(step: Int, immersive: Bool) -> CGFloat {
        let sizes = sizes(immersive: immersive)
        return sizes[min(max(step, 0), sizes.count - 1)]
    }
}

/// 一覧からの注釈の変更（語・発言は番号で渡し、録音には時刻で書く）
enum NoteEdit {
    case highlight(words: ClosedRange<Int>, color: Int, comment: String)
    case recolor(UUID, Int)
    case comment(UUID, String)
    case delete(UUID)
    /// 発言のブックマークを付け外しする
    case bookmark(block: Int)
    /// 発言の前に見出しを入れる
    case heading(block: Int, level: Int, title: String)
    /// 語の前に見出しを入れる（発言の途中なら、そこで発言を分ける）
    case headingAt(word: Int, level: Int, title: String)
    case editHeading(UUID, level: Int, title: String)
}

extension Recording {
    func apply(_ edit: NoteEdit, model: TranscriptModel) {
        switch edit {
        case .highlight(let words, let color, let comment):
            guard model.words.indices.contains(words.lowerBound), model.words.indices.contains(words.upperBound) else { return }
            addHighlight(from: model.words[words.lowerBound].start, to: model.words[words.upperBound].end, color: color, comment: comment)
        case .recolor(let id, let color): updateAnnotation(id) { $0.color = color }
        case .comment(let id, let text): updateAnnotation(id) { $0.text = text }
        case .delete(let id): removeAnnotation(id)
        case .bookmark(let b):
            if model.blocks.indices.contains(b) { toggleBookmark(at: model.blocks[b].start) }
        case .heading(let b, let level, let title):
            if model.blocks.indices.contains(b) { addHeading(at: model.blocks[b].start, level: level, title: title) }
        case .headingAt(let w, let level, let title):
            if model.words.indices.contains(w) { addHeading(at: model.words[w].start, level: level, title: title) }
        case .editHeading(let id, let level, let title):
            updateAnnotation(id) {
                $0.level = level
                $0.text = title
            }
        }
    }
}

/// 文字起こしの画面の操作の窓口: 右のパネルやメニューの「移動」から、見出しや注釈へ移る（再生位置を移し、一覧を送る）
@Observable
final class TranscriptController {
    @ObservationIgnored weak var list: TranscriptListView?
    @ObservationIgnored var player: AudioPlayer?
    @ObservationIgnored var recording: Recording?

    /// 発言 b の頭へ（play なら再生も始める）
    func jump(toBlock b: Int, play: Bool = false) {
        guard let model = recording?.model, model.blocks.indices.contains(b) else { return }
        player?.seek(to: model.blocks[b].start, play: play)
        list?.reveal(b)
    }

    /// 語 w へ（play なら再生も始める）
    func jump(toWord w: Int, play: Bool = false) {
        guard let model = recording?.model, model.words.indices.contains(w) else { return }
        player?.seek(to: model.words[w].start, play: play)
        list?.reveal(model.words[w].block, anchor: 0.3)
    }

    /// 前・次の見出しへ（再生位置より後の最初の見出し、前は少し戻った所より前の最後の見出し）
    func moveHeading(forward: Bool) {
        guard let recording, let model = recording.model, let player else { return }
        let blocks = model.resolve(recording.notes).headings.map(\.block)
        let t = player.currentTime
        let target = forward ? blocks.first { model.blocks[$0].start > t + 0.5 } : blocks.last { model.blocks[$0].start < t - 1.5 }
        if let target { jump(toBlock: target) }
    }

    /// 前・次の注釈（ハイライト・ブックマーク）へ
    func moveAnnotation(forward: Bool) {
        guard let recording, let model = recording.model, let player else { return }
        let notes = model.resolve(recording.notes)
        let marks = (notes.highlights.map { (model.words[$0.words.lowerBound].start, $0.words.lowerBound) }
            + notes.bookmarks.keys.map { (model.blocks[$0].start, model.blocks[$0].words.lowerBound) }).sorted { $0.0 < $1.0 }
        let t = player.currentTime
        if let target = forward ? marks.first(where: { $0.0 > t + 0.5 }) : marks.last(where: { $0.0 < t - 1.5 }) {
            jump(toWord: target.1)
        }
    }
}

/// 文字起こしの表示内容。変わった発言だけを並べ直す
struct TranscriptDocument: Equatable {
    struct Block: Equatable {
        var speaker: String
        var name: String
        var start: Double
        var words: Range<Int>
        /// この発言の前の見出し
        var headings: [ResolvedNotes.Heading] = []
        /// 本文と、語ごとの本文の中の範囲（原文は語をつなげたもの。整形した表示は整形後で、消した語は長さ 0）
        var text: String
        var ranges: [NSRange]
        /// 整形した表示で省いた発言（並べない）
        var hidden = false
        /// まだ整形していない（原文のまま薄く出す）
        var pending = false
        /// 本文の代わりの説明（省いた発言の「省略（相槌）」）
        var note: String?
        /// 見比べで左に出す原文
        var original: Original?
    }

    /// 見比べの左の原文: 本文・語ごとの範囲・整形で取り除いた所
    struct Original: Equatable {
        var text: String
        var ranges: [NSRange]
        var removed: [NSRange]
    }

    var blocks: [Block] = []
    var words: [TranscriptModel.Word] = []
    var colors: [String: NSColor] = [:]
    /// 処理中の進み具合（「文字起こしを作成中… 0:23 / 1:15」）。処理中でなければ nil
    var live: String?
    /// 見比べ（左に原文、右に整形後）
    var compare = false
    /// 没入モード（今の発言を大きく、前後の発言を薄く）
    var immersive = false
    /// 本文の文字の大きさ（pt）
    var textSize = TextSize.normal[TextSize.defaultStep]

    func text(of b: Int) -> String { blocks[b].text }

    /// 語 w を含む文の最初の語（吹き出しの頭より前には戻らない）
    func sentenceStart(of w: Int) -> Int {
        TranscriptModel.sentenceStart(of: w, in: words, from: blocks[words[w].block].words.lowerBound)
    }
}

private struct TranscriptListRepresentable: NSViewRepresentable {
    let document: TranscriptDocument
    let highlights: [ResolvedNotes.Highlight]
    let bookmarks: [Int: UUID]
    let player: AudioPlayer
    let filter: String?
    let hits: Set<Int>
    let activeHit: [Int]?
    let following: Bool
    let recall: Int
    let controller: TranscriptController
    let events: TranscriptListView.Events

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let list = TranscriptListView(player: player)
        scroll.documentView = list
        controller.list = list
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? TranscriptListView else { return }
        controller.list = view
        view.events = events
        view.following = following
        view.show(document)
        view.annotate(highlights: highlights, bookmarks: bookmarks)
        view.mark(filter: filter, hits: hits, active: activeHit ?? [])
        view.recall(recall)
    }
}
