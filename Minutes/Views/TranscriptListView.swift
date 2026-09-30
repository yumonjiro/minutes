import AppKit
import SwiftUI

/// 本文の寸法: 時刻の右端・アイコンの左端と大きさ・発言の左端（列の左端から）、列の最大幅、上下左右の余白、
/// 見出しの行の高さと本文までの間、発言の間、背景のはみ出し、文字
enum TranscriptMetrics {
    static let timeEnd: CGFloat = 46, iconX: CGFloat = 58, icon: CGFloat = 20, textX: CGFloat = 88, column: CGFloat = 760
    static let inset = CGSize(width: 32, height: 24)
    static let headerHeight: CGFloat = 20, headerGap: CGFloat = 6, rowGap: CGFloat = 22
    static let pad = CGSize(width: 12, height: 8)
    static let nameFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    static let initialFont = NSFont.systemFont(ofSize: 10, weight: .bold)
    static let noteFont = NSFont.systemFont(ofSize: 13)
    /// 見出し（議題・小見出し）の文字と行の高さ、前の間
    static let headingFont = [NSFont.systemFont(ofSize: 17, weight: .semibold), NSFont.systemFont(ofSize: 14, weight: .semibold)]
    static let headingHeight: [CGFloat] = [26, 22], headingSpace: [CGFloat] = [18, 8]
    /// 見比べ（左に原文、右に整形）の列の最大幅・左右の本文の間（右の列のアイコンを含む）・上の「原文」「整形後」の行の高さ
    static let compareColumn: CGFloat = 1240, compareGap: CGFloat = 56, compareHeader: CGFloat = 30
    /// 没入モード: 発言の間・上の余白。今の発言は画面の上から 3 割の所に置く（本文の文字は太く、大きさは TextSize）
    static let immersiveRowGap: CGFloat = 40, immersiveTop: CGFloat = 120, immersiveAnchor: CGFloat = 0.3
    /// 没入モードの前後の発言の濃さ: 再生し終えた発言は落ち着かせ、これからの発言（今の発言のまだの所も）は少し明るく
    static let immersivePlayed: CGFloat = 0.3, immersiveUpcoming: CGFloat = 0.55
}

/// 本文の中の位置: 発言の番号と、その本文の中の文字の位置（UTF-16）
struct TextPosition: Comparable {
    var block: Int
    var offset: Int

    static func < (a: Self, b: Self) -> Bool { (a.block, a.offset) < (b.block, b.offset) }
}

/// 文字起こしの一覧（行も文字も自分で描く）。印が変わったら変わった所だけを描き直す。
/// 描くのは高さ 512 の帯（TileLayer）で、見えている所とその前後の帯だけを置く（一覧全体の大きな絵を 1 枚持つと、
/// 少し描き直すたびにその絵全体を GPU とやり取りして重くなるため）。スクロールでは帯を動かすだけで、新しく見えた帯だけを描く。
/// 全体は開いたとき（と幅が変わったとき）に並べるので、スクロールバーの大きさは変わらない。
/// 注釈: 見出しは発言の前の行として並べ、ハイライト（とコメントの印）とブックマーク（左の余白）は描くときに足す（並べ直さない）
final class TranscriptListView: NSView {
    struct Events {
        var userScrolled: () -> Void
        var rename: (String, String) -> Void
        var filter: (String?) -> Void
        var edit: (NoteEdit) -> Void
        /// 見えている最初の発言（送るたびに呼ぶ。発言の整形はここから進める）
        var visible: (Int) -> Void
    }

    /// 見出し 1 つの並べ方
    private struct HeadingLine {
        var heading: ResolvedNotes.Heading
        var line: CTLine
        /// 見出しの行（列の幅）と、文字の幅・ベースライン
        var rect: CGRect
        var textWidth: CGFloat
        var baseline: CGFloat
    }

    /// 1 つの発言の並べ方（この表示の座標）
    private struct Row {
        /// この発言を並べ始めた所（見出しの前の間を含む）と、次の発言を並べ始める所
        var top: CGFloat
        var next: CGFloat
        /// 発言の前の見出し
        var headings: [HeadingLine]
        /// 時刻・名前の行の上端から本文の下端まで（列の幅）
        var frame: CGRect
        var body: TextLayout
        var bodyOrigin: CGPoint
        /// 本文の中の語の範囲（UTF-16。発言の中の語の順。整形して消した語は長さ 0）
        var words: [NSRange]
        var time: CTLine, name: CTLine, initial: CTLine
        /// 話者名の所（見比べは左右の列に 1 つずつ）
        var nameRects: [CGRect]
        /// 整形した表示で省いた発言（高さ 0。描かず、選べない）
        var hidden = false
        /// 見比べの左の原文: 本文・左上・語の範囲・整形で消した所
        var original: (body: TextLayout, origin: CGPoint, words: [NSRange], removed: [NSRange])?
        /// 本文の代わりの説明（省いた発言の「省略（相槌）」）
        var note: CTLine?
        /// 背景（再生中・ポインタの下）を塗る範囲（省いた発言は高さ 0）
        var background: CGRect {
            let pad = TranscriptMetrics.pad
            return hidden ? CGRect(x: frame.minX, y: frame.minY - pad.height, width: frame.width, height: 0)
                : frame.insetBy(dx: -pad.width, dy: -pad.height)
        }
        /// 左の余白のブックマークの印の所
        var gutter: CGRect { CGRect(x: frame.minX - 32, y: frame.minY - 4, width: 28, height: TranscriptMetrics.headerHeight + 8) }

        /// 縦に dy ずらす（前の発言の高さが変わったとき）
        mutating func shift(_ dy: CGFloat) {
            top += dy
            next += dy
            frame.origin.y += dy
            bodyOrigin.y += dy
            for i in nameRects.indices { nameRects[i].origin.y += dy }
            for i in headings.indices {
                headings[i].rect.origin.y += dy
                headings[i].baseline += dy
            }
            original?.origin.y += dy
        }
    }

    var events = Events(userScrolled: {}, rename: { _, _ in }, filter: { _ in }, edit: { _ in }, visible: { _ in })
    var following = true

    private let player: AudioPlayer
    private(set) var document = TranscriptDocument()
    private var rows: [Row] = []
    private var laidOutWidth: CGFloat = 0
    /// 処理中の進み具合の行（くるくると文字）
    private var liveFrame: CGRect?
    private var liveLine: CTLine?
    private let spinner = NSProgressIndicator()
    /// 置いている帯（番号 i の帯は y が i × tileHeight から）
    private var tiles: [Int: TileLayer] = [:]
    private static let tileHeight: CGFloat = 512

    /// 描くときに足す注釈（ハイライトは始まりの順、ブックマークは発言の番号）
    private var highlights: [ResolvedNotes.Highlight] = []
    private var bookmarks: [Int: UUID] = [:]

    /// 再生中の発言と語、ポインタの下の発言と語（名前の上か）、絞り込み、検索の一致
    private var now: Int?, nowWord: Int?
    /// 没入モードで前に出す発言（今の発言、発言の合間なら直前の発言）と、話し終えた所（開始が再生位置より前の最後の語）
    private var focus: Int?, spoken: Int?
    private var hovered: (block: Int, word: Int?, onName: Bool)?
    /// ポインタが乗っている、発言と発言の間（議題を入れる所。その後の発言の番号）
    private var hoveredGap: Int?
    private var filter: String?
    private var hits: Set<Int> = [], active: [Int] = []
    private var wasPlaying = false
    private var recalled = 0
    private var pendingReveal: (block: Int, fraction: CGFloat, anchor: CGFloat)?

    /// 選択（押した所とドラッグしている所。同じなら選択なし）と、マウスを押したときの状態、選択のすぐ上に出すバー
    private var selection: (anchor: TextPosition, head: TextPosition)?
    private var press: (point: NSPoint, clicks: Int)?
    private var dragging = false
    private var autoscrollTimer: Timer?
    private var toolbar: NSHostingView<SelectionToolbar>?

    init(player: AudioPlayer) {
        self.player = player
        super.init(frame: .zero)
        wantsLayer = true
        autoresizingMask = [.width]  // スクロールの枠の幅に合わせる
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true
        addSubview(spinner)
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("文字起こし")
        observePlayer()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let superview { setFrameSize(NSSize(width: superview.bounds.width, height: frame.height)) }
    }

    override func accessibilityValue() -> Any? {
        document.blocks.indices.filter { !document.blocks[$0].hidden }
            .map { "\(formatTime(document.blocks[$0].start)) \(document.blocks[$0].name)\n\(document.text(of: $0))" }
            .joined(separator: "\n\n")
    }

    // MARK: 表示内容と並べ方

    /// 表示内容を反映する。発言の並びが同じなら変わった発言だけ（整形の結果が届いたとき）、
    /// そうでなければ変わった最初の発言から後ろを並べ直す（処理中は最後の発言と進み具合だけ）。
    /// 並べ直しても、見えている最初の発言が同じ位置に残るように送り直す（表示の仕方を切り替えても、読んでいた所のまま）
    func show(_ new: TranscriptDocument) {
        guard new != document else { return }
        let old = document
        func same(_ b: Int) -> Bool { old.blocks[b] == new.blocks[b] && old.words[old.blocks[b].words] == new.words[new.blocks[b].words] }
        // 見た目の設定（色・見比べ・没入モード・文字の大きさ）が変わったら、全体を並べ直す
        let sameStyle = old.colors == new.colors && old.compare == new.compare && old.immersive == new.immersive && old.textSize == new.textSize
        let atBottom = isNearBottom, anchor = scrollAnchor()
        document = new
        if sameStyle, old.blocks.count == new.blocks.count, rows.count == new.blocks.count, old.live == new.live,
           abs(laidOutWidth - bounds.width) <= 0.5 {
            let changed = new.blocks.indices.filter { !same($0) }
            if let s = selection, changed.contains(where: { (min(s.anchor, s.head).block...max(s.anchor, s.head).block).contains($0) }) {
                clearSelection()
            }
            relayout(changed)
        } else {
            var first = 0
            if sameStyle {
                while first < min(old.blocks.count, new.blocks.count), same(first) { first += 1 }
            }
            if let s = selection, max(s.anchor.block, s.head.block) >= first { clearSelection() }  // 選んでいた発言が変わった
            layoutRows(from: first)
        }
        if atBottom, new.live != nil, !player.isPlaying {
            scroll(toY: .greatestFiniteMagnitude)
        } else if new.immersive, !old.immersive || old.blocks.isEmpty, let focus {
            reveal(focus, anchor: TranscriptMetrics.immersiveAnchor)  // 没入モードにしたら、今の発言を前に
        } else {
            restore(anchor)
        }
        if old.blocks.isEmpty, following, player.isPlaying, let b = now { reveal(b) }  // 表示する前に再生が始まっていた
        #if DEBUG
        if old.blocks.isEmpty { Debug.transcriptShown(self) }
        #endif
    }

    /// ハイライトとブックマークを反映する（並べ直さずに描き直す）
    func annotate(highlights: [ResolvedNotes.Highlight], bookmarks: [Int: UUID]) {
        guard highlights != self.highlights || bookmarks != self.bookmarks else { return }
        self.highlights = highlights
        self.bookmarks = bookmarks
        redrawAll()
    }

    /// 本文の列の左端と幅（最大 760、見比べは 1240 で、窓の中央）
    private var column: (x: CGFloat, width: CGFloat) {
        let limit = document.compare ? TranscriptMetrics.compareColumn : TranscriptMetrics.column
        let width = min(limit, max(200, bounds.width - TranscriptMetrics.inset.width * 2))
        return ((bounds.width - width) / 2, width)
    }

    /// 本文の左端と幅。見比べは左右に分け、左に原文、右に整形した本文（選択・コピーは右）
    private var textColumns: (main: (x: CGFloat, width: CGFloat), original: (x: CGFloat, width: CGFloat)?) {
        let m = TranscriptMetrics.self, col = column, full = col.width - m.textX
        guard document.compare else { return ((col.x + m.textX, full), nil) }
        let half = (full - m.compareGap) / 2
        return ((col.x + m.textX + half + m.compareGap, half), (col.x + m.textX, half))
    }

    /// 本文の文字と行間（大きさは表示の設定。没入モードは太く、行間も広く）
    private var bodyStyle: (font: NSFont, spacing: CGFloat) {
        let size = document.textSize
        return document.immersive ? (.systemFont(ofSize: size, weight: .semibold), (size * 0.45).rounded()) : (.systemFont(ofSize: size), (size * 0.4).rounded())
    }

    /// 最初の発言を並べ始める所
    private var firstTop: CGFloat {
        TranscriptMetrics.inset.height + TranscriptMetrics.pad.height + (document.compare ? TranscriptMetrics.compareHeader : 0)
            + (document.immersive ? TranscriptMetrics.immersiveTop : 0)
    }

    /// 発言 first から後ろを並べ直し、高さを合わせる（幅が変わったときは全部）
    private func layoutRows(from first: Int) {
        guard bounds.width > 0 else { return }
        let start = min(first, rows.count)
        rows.removeSubrange(start...)
        var y = start == 0 ? firstTop : rows[start - 1].next
        for b in start..<document.blocks.count {
            rows.append(makeRow(b, top: y))
            y = rows[b].next
        }
        finishLayout()
    }

    /// 変わった発言だけを並べ直し、後ろの発言はずらす（整形の結果が届いたとき。長い会議でも軽い）
    private func relayout(_ changed: [Int]) {
        guard let first = changed.first else { return }
        let changed = Set(changed)
        var y = rows[first].top
        for b in first..<rows.count {
            if changed.contains(b) {
                rows[b] = makeRow(b, top: y)
            } else if rows[b].top != y {
                rows[b].shift(y - rows[b].top)
            }
            y = rows[b].next
        }
        finishLayout()
    }

    /// 発言 b を y から並べる: 見出し（議題・小見出し）、時刻・名前の行、本文（見比べは左に原文）
    private func makeRow(_ b: Int, top: CGFloat) -> Row {
        let m = TranscriptMetrics.self, col = column, texts = textColumns, block = document.blocks[b]
        var y = top, headings: [HeadingLine] = []
        for h in block.headings {
            let i = h.level == 1 ? 0 : 1
            if b > 0 || !headings.isEmpty { y += m.headingSpace[i] }
            let text = line(h.title.isEmpty ? "無題の見出し" : h.title, font: m.headingFont[i])
            headings.append(HeadingLine(heading: h, line: text, rect: CGRect(x: col.x, y: y, width: col.width, height: m.headingHeight[i]),
                                        textWidth: CTLineGetTypographicBounds(text, nil, nil, nil), baseline: y + m.headingHeight[i] - 7))
            y += m.headingHeight[i]
        }
        if !headings.isEmpty { y += 14 }
        let bodyY = y + m.headerHeight + m.headerGap
        let name = line(block.name, font: m.nameFont), nameWidth = CTLineGetTypographicBounds(name, nil, nil, nil)
        let (font, spacing) = bodyStyle
        var row = Row(top: top, next: y, headings: headings, frame: CGRect(x: col.x, y: y, width: col.width, height: 0),
                      body: TextLayout(block.hidden ? "" : block.text, font: font, width: texts.main.width, lineSpacing: spacing),
                      bodyOrigin: CGPoint(x: texts.main.x, y: bodyY), words: block.ranges,
                      time: line(formatTime(block.start), font: m.timeFont), name: name, initial: line(initial(of: block.name), font: m.initialFont),
                      nameRects: ([col.x + m.textX] + (texts.original == nil ? [] : [texts.main.x]))
                          .map { CGRect(x: $0 - 2, y: y, width: nameWidth + 4, height: m.headerHeight) },
                      hidden: block.hidden)
        guard !block.hidden else { return row }
        if let o = block.original, let left = texts.original {
            row.original = (TextLayout(o.text, font: font, width: left.width, lineSpacing: spacing), CGPoint(x: left.x, y: bodyY),
                            o.ranges, o.removed)
        }
        row.note = block.note.map { line($0, font: m.noteFont) }
        let height = max(row.body.height, row.original?.body.height ?? 0, row.note == nil ? 0 : 18)
        row.frame.size.height = m.headerHeight + m.headerGap + height
        row.next = row.frame.maxY + (document.immersive ? m.immersiveRowGap : m.rowGap)
        return row
    }

    /// 並べた後: 処理中の行、全体の高さ、帯、描き直し
    private func finishLayout() {
        let m = TranscriptMetrics.self, col = column
        let bottom = rows.last(where: { !$0.hidden })?.frame.maxY ?? firstTop
        var y: CGFloat
        if let live = document.live {
            let top = rows.isEmpty ? bottom : bottom + 18
            liveFrame = CGRect(x: col.x + m.textX, y: top, width: col.width - m.textX, height: 18)
            liveLine = line(live, font: m.noteFont)
            spinner.frame = CGRect(x: col.x + m.textX, y: top + 2, width: 14, height: 14)
            spinner.isHidden = false
            spinner.startAnimation(nil)
            y = top + 18
        } else {
            liveFrame = nil
            liveLine = nil
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            // 没入モードは、最後の発言も画面の上の方まで送れるように下を空ける
            y = bottom + (document.immersive ? max(300, (enclosingScrollView?.contentSize.height ?? 0) * 0.7) : m.pad.height)
        }
        if abs(laidOutWidth - bounds.width) > 0.5 { removeTiles() }  // 幅が変わったら帯を作り直す
        laidOutWidth = bounds.width
        let height = max(y + m.inset.height, enclosingScrollView?.contentSize.height ?? 0)
        if abs(frame.height - height) > 0.5 { super.setFrameSize(NSSize(width: frame.width, height: height)) }
        placeTiles()
        redrawAll()
        placeToolbar()
        window?.invalidateCursorRects(for: self)
        if let p = pendingReveal, enclosingScrollView?.contentView.bounds.height ?? 0 > 0 {
            pendingReveal = nil
            reveal(p.block, at: p.fraction, anchor: p.anchor)
        }
    }

    /// 見えている最初の発言と、その上端の、見えている範囲の上端からの位置（上端まで送っていなければ無し）
    private func scrollAnchor() -> (block: Int, offset: CGFloat)? {
        guard let clip = enclosingScrollView?.contentView, clip.bounds.minY > 0, !rows.isEmpty else { return nil }
        var b = firstRow(atOrBelow: clip.bounds.minY)
        while b < rows.count, rows[b].hidden { b += 1 }
        return b < rows.count ? (b, rows[b].frame.minY - clip.bounds.minY) : nil
    }

    /// 並べ直した後、scrollAnchor で覚えた発言が同じ位置に来るように送る（動きを付けずに）
    private func restore(_ anchor: (block: Int, offset: CGFloat)?) {
        guard let anchor, rows.indices.contains(anchor.block), let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let y = min(max(0, rows[anchor.block].frame.minY - anchor.offset), max(0, frame.height - clip.bounds.height))
        guard abs(y - clip.bounds.minY) > 0.5 else { return }
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    private func line(_ text: String, font: NSFont) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]))
    }

    /// 幅が変わったら並べ直す。発言が多い（長い会議の）ときは、窓の大きさを変え終えてから並べ直す（変えている間に毎回並べると重い）
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if abs(newSize.width - laidOutWidth) > 0.5, !inLiveResize || rows.count < 300 { layoutRows(from: 0) }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if abs(bounds.width - laidOutWidth) > 0.5 { layoutRows(from: 0) }
    }

    /// 見えている範囲（スクロールの枠）の大きさが決まったら、頼まれていた送り先へ送る
    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        if let p = pendingReveal, laidOutWidth > 0, (superview?.bounds.height ?? 0) > 0 {
            pendingReveal = nil
            reveal(p.block, at: p.fraction, anchor: p.anchor)
        }
    }

    // MARK: 帯

    /// 見えている所とその前後 1 枚ずつの帯を置き、ほかは外す
    private func placeTiles() {
        guard bounds.width > 0, let layer, let clip = enclosingScrollView?.contentView else { return }
        let h = Self.tileHeight, visible = convert(clip.bounds, from: clip)
        let first = max(0, Int(floor((visible.minY - h) / h))), last = max(first, Int(floor(min(visible.maxY + h, bounds.height - 1) / h)))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, tile) in tiles where i < first || i > last {
            tile.removeFromSuperlayer()
            tiles[i] = nil
        }
        for i in first...last where tiles[i] == nil {
            let tile = TileLayer()
            tile.list = self
            tile.contentsScale = window?.backingScaleFactor ?? 2
            tile.frame = CGRect(x: 0, y: CGFloat(i) * h, width: bounds.width, height: h)
            layer.insertSublayer(tile, at: 0)  // くるくる・選択のバー（サブビュー）より下
            tile.setNeedsDisplay()
            tiles[i] = tile
        }
        CATransaction.commit()
    }

    private func removeTiles() {
        tiles.values.forEach { $0.removeFromSuperlayer() }
        tiles = [:]
    }

    /// この表示の座標の rect を描き直す
    private func redraw(_ rect: CGRect) {
        for tile in tiles.values where tile.frame.intersects(rect) {
            tile.setNeedsDisplay(rect.offsetBy(dx: -tile.frame.minX, dy: -tile.frame.minY))
        }
    }

    private func redrawAll() {
        tiles.values.forEach { $0.setNeedsDisplay() }
    }

    /// 別の画面へ移って画素の細かさが変わったら、帯を描き直す
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        for tile in tiles.values { tile.contentsScale = window?.backingScaleFactor ?? 2 }
        redrawAll()
    }

    // MARK: 描き方

    /// 帯 1 枚の中身を描く（dirtyRect とコンテキストは、この表示の座標）
    fileprivate func drawContent(_ dirtyRect: CGRect, in ctx: CGContext) {
        ctx.prepareForFlippedText()
        if let left = textColumns.original, dirtyRect.minY < firstTop {
            // 見比べ: 左右の列の名前
            let baseline = TranscriptMetrics.inset.height + 12, font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            ctx.setFillColor(NSColor.tertiaryLabelColor.cgColor)
            for (text, x) in [("原文（取り除いた所に線）", left.x), ("整形後", textColumns.main.x)] {
                ctx.textPosition = CGPoint(x: x, y: baseline)
                CTLineDraw(line(text, font: font), ctx)
            }
        }
        var b = firstRow(atOrBelow: dirtyRect.minY)
        while b < rows.count, (rows[b].headings.first?.rect.minY ?? rows[b].background.minY) <= dirtyRect.maxY {
            if !rows[b].hidden { drawRow(b, in: ctx, dirty: dirtyRect) }
            b += 1
        }
        if let liveFrame, let liveLine, liveFrame.intersects(dirtyRect) {
            ctx.setFillColor(NSColor.secondaryLabelColor.cgColor)
            ctx.textPosition = CGPoint(x: liveFrame.minX + 22, y: liveFrame.minY + 13)
            CTLineDraw(liveLine, ctx)
        }
        if let b = hoveredGap, let r = gapRect(before: b), r.intersects(dirtyRect) { drawGap(r, in: ctx) }
    }

    private func drawRow(_ b: Int, in ctx: CGContext, dirty: CGRect) {
        let m = TranscriptMetrics.self, row = rows[b], block = document.blocks[b]
        let color = document.colors[block.speaker] ?? .secondaryLabelColor
        drawHeadings(row, in: ctx)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // 絞り込みで外れた話者の発言は薄く。没入モードは、今の発言とポインタの下の発言だけ白く、再生し終えた発言は落ち着かせ、
        // これからの発言は少し明るく（Spotify の歌詞のように、済んだ所とこれからの所が色でわかる）
        let focused = document.immersive && b == focus, pointed = document.immersive && hovered?.block == b
        var alpha: CGFloat = 1
        if let filter, filter != block.speaker { alpha = 0.3 }
        if document.immersive, !focused, !pointed {
            alpha *= (focus.map { b < $0 } ?? false) ? TranscriptMetrics.immersivePlayed : TranscriptMetrics.immersiveUpcoming
        }
        if alpha < 1 { ctx.setAlpha(alpha) }

        // 背景: 再生中の発言は薄い灰色、ポインタの下の発言はごく薄い灰色（没入モードは背景を塗らない）
        if document.immersive {
        } else if b == now {
            ctx.fillRoundedRect(row.background, radius: 10, color: .labelColor.withAlphaComponent(0.06))
        } else if hovered?.block == b {
            ctx.fillRoundedRect(row.background, radius: 10, color: .labelColor.withAlphaComponent(0.035))
        }
        // 左の余白: ブックマークの印（ポインタが乗っている発言には、付けられることを示す薄い印）
        if bookmarks[b] != nil {
            drawBookmark(in: row.gutter, filled: true, ctx: ctx)
        } else if hovered?.block == b {
            drawBookmark(in: row.gutter, filled: false, ctx: ctx)
        }

        // 見出し: 時刻（右寄せ）・アイコン・名前（話者の色。ポインタが乗ると下線）。見比べは右の列にもアイコンと名前
        let baseline = row.frame.minY + 14.5
        ctx.setFillColor(NSColor.secondaryLabelColor.cgColor)
        ctx.textPosition = CGPoint(x: row.frame.minX + m.timeEnd - CTLineGetTypographicBounds(row.time, nil, nil, nil), y: baseline)
        CTLineDraw(row.time, ctx)
        let bounds = CTLineGetBoundsWithOptions(row.initial, .useOpticalBounds)
        for name in row.nameRects {
            let x = name.minX + 2
            let icon = CGRect(x: x - (m.textX - m.iconX), y: row.frame.minY + (m.headerHeight - m.icon) / 2, width: m.icon, height: m.icon)
            ctx.setFillColor(color.withAlphaComponent(0.16).cgColor)
            ctx.fillEllipse(in: icon)
            ctx.setFillColor(color.cgColor)
            ctx.textPosition = CGPoint(x: icon.midX - bounds.width / 2 - bounds.minX, y: icon.midY + bounds.minY + bounds.height / 2)
            CTLineDraw(row.initial, ctx)
            ctx.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(row.name, ctx)
            if hovered?.block == b, hovered?.onName == true {
                ctx.fill(CGRect(x: x, y: baseline + 2.5, width: name.width - 4, height: 1))
            }
        }

        // 本文の印（ハイライト・検索の一致・ポインタの下の語・再生中の語・選択）と本文。見比べは左の原文にも同じ印を付ける
        func rects(_ words: ClosedRange<Int>, original: Bool = true) -> [CGRect] {
            let range = block.words, lo = max(words.lowerBound, range.lowerBound), hi = min(words.upperBound, range.upperBound - 1)
            guard lo <= hi else { return [] }
            var result = span(row.words, lo - range.lowerBound, hi - range.lowerBound, in: row.body, at: row.bodyOrigin)
            if original, let o = row.original { result += span(o.words, lo - range.lowerBound, hi - range.lowerBound, in: o.body, at: o.origin) }
            return result
        }
        let range = block.words
        for h in highlights where h.words.lowerBound < range.upperBound && h.words.upperBound >= range.lowerBound {
            for r in rects(h.words) { ctx.fillRoundedRect(r.insetBy(dx: -1, dy: -1.5), radius: 3, color: HighlightColor.fill(h.color)) }
            if !h.comment.isEmpty, range.contains(h.words.upperBound), let last = rects(h.words, original: false).last {
                drawCommentMark(in: commentMark(after: last), color: HighlightColor.solid[h.color], ctx: ctx)
            }
        }
        for w in hits where range.contains(w) && !active.contains(w) {
            for r in rects(w...w) {
                ctx.setStrokeColor(NSColor.systemOrange.cgColor)
                ctx.setLineWidth(1.5)
                ctx.addPath(CGPath(roundedRect: r.insetBy(dx: -1.5, dy: -1), cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
                ctx.strokePath()
            }
        }
        for w in active where range.contains(w) {
            for r in rects(w...w) { ctx.fillRoundedRect(r.insetBy(dx: -1.5, dy: -1), radius: 3.5, color: .controlAccentColor.withAlphaComponent(0.4)) }
        }
        if hovered?.block == b, let w = hovered?.word, w != nowWord, range.contains(w), !document.immersive {
            for r in rects(w...w) { ctx.fillRoundedRect(r.insetBy(dx: -1.5, dy: -1), radius: 3.5, color: .labelColor.withAlphaComponent(0.1)) }
        }
        if let w = nowWord, range.contains(w), !focused {
            for r in rects(w...w) { ctx.fillRoundedRect(r.insetBy(dx: -1.5, dy: -1), radius: 3.5, color: color.withAlphaComponent(0.25)) }
        }
        if let r = selectedRange(in: b) {
            let selected = window?.isKeyWindow == true ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor
            ctx.setFillColor(selected.cgColor)
            // 行の間も塗って、行をまたぐ選択が途切れないようにする
            let gap = (row.body.lineHeight - row.body.glyphHeight) / 2
            for rect in row.body.rects(for: r) { ctx.fill(rect.offsetBy(dx: row.bodyOrigin.x, dy: row.bodyOrigin.y).insetBy(dx: 0, dy: -gap)) }
        }
        if focused {
            // 没入モードの今の発言: 話し終えた所は濃く、まだの所は薄く、今の語は話者の色（歌詞のように読み進められる）
            let lower = range.lowerBound
            let end = spoken.map { $0 < lower ? 0 : $0 >= range.upperBound ? row.body.length : NSMaxRange(row.words[$0 - lower]) } ?? 0
            ctx.setFillColor(NSColor.labelColor.withAlphaComponent(TranscriptMetrics.immersiveUpcoming).cgColor)
            row.body.draw(in: ctx, at: row.bodyOrigin, visible: dirty)
            overdraw(row, NSRange(location: 0, length: end), color: .labelColor, in: ctx, dirty: dirty)
            if let w = nowWord, range.contains(w) { overdraw(row, row.words[w - lower], color: color, in: ctx, dirty: dirty) }
        } else {
            // まだ整形していない発言は薄く（原文のまま）
            ctx.setFillColor((block.pending ? NSColor.secondaryLabelColor : NSColor.labelColor).cgColor)
            row.body.draw(in: ctx, at: row.bodyOrigin, visible: dirty)
        }
        if let note = row.note {
            ctx.setFillColor(NSColor.tertiaryLabelColor.cgColor)
            ctx.textPosition = CGPoint(x: row.bodyOrigin.x, y: row.bodyOrigin.y + 14)
            CTLineDraw(note, ctx)
        }
        // 見比べの左: 原文を少し薄く、取り除いた所は赤く敷いて線で消す
        if let o = row.original {
            let cuts = o.removed.flatMap { o.body.rects(for: $0) }.map { $0.offsetBy(dx: o.origin.x, dy: o.origin.y) }
            for r in cuts { ctx.fillRoundedRect(r.insetBy(dx: -1, dy: -1.5), radius: 3, color: .systemRed.withAlphaComponent(0.1)) }
            ctx.setFillColor(NSColor.secondaryLabelColor.cgColor)
            o.body.draw(in: ctx, at: o.origin, visible: dirty)
            ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.7).cgColor)
            for r in cuts { ctx.fill(CGRect(x: r.minX, y: (r.midY - 0.5).rounded(), width: r.width, height: 1)) }
        }
    }

    /// 本文の range の所だけを color で描き直す（その文字の所に切り抜いて、もう一度描く）
    private func overdraw(_ row: Row, _ range: NSRange, color: NSColor, in ctx: CGContext, dirty: CGRect) {
        let gap = (row.body.lineHeight - row.body.glyphHeight) / 2
        let rects = row.body.rects(for: range).map { $0.offsetBy(dx: row.bodyOrigin.x, dy: row.bodyOrigin.y).insetBy(dx: -1, dy: -gap) }
        guard !rects.isEmpty else { return }
        ctx.saveGState()
        ctx.clip(to: rects)
        ctx.setFillColor(color.cgColor)
        row.body.draw(in: ctx, at: row.bodyOrigin, visible: dirty)
        ctx.restoreGState()
    }

    /// 語 a〜z（発言の中の番号）を囲む矩形（この表示の座標）。消した語は長さ 0 なので、それだけなら無し
    private func span(_ ranges: [NSRange], _ a: Int, _ z: Int, in body: TextLayout, at origin: CGPoint) -> [CGRect] {
        let start = ranges[a].location, end = NSMaxRange(ranges[z])
        guard end > start else { return [] }
        return body.rects(for: NSRange(location: start, length: end - start)).map { $0.offsetBy(dx: origin.x, dy: origin.y) }
    }

    /// 発言と発言の間の、議題を入れる所の印: 発言の背景の左の外に「＋ 議題」の札を突き出し、そこから背景の右端まで細い線（アクセントの色）
    private func drawGap(_ r: CGRect, in ctx: CGContext) {
        let marker = gapMarker(r), y = marker.midY, end = column.x + column.width + TranscriptMetrics.pad.width
        ctx.fillRoundedRect(marker, radius: marker.height / 2, color: .controlAccentColor.withAlphaComponent(0.16))
        ctx.setFillColor(NSColor.controlAccentColor.cgColor)
        ctx.textPosition = CGPoint(x: marker.minX + 7, y: y + 4)
        CTLineDraw(gapLabel, ctx)
        ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor)
        ctx.fill(CGRect(x: marker.maxX + 4, y: (y - 0.5).rounded(), width: max(0, end - marker.maxX - 4), height: 1))
    }

    private let gapLabel = CTLineCreateWithAttributedString(NSAttributedString(string: "＋ 議題", attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: .semibold), NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
    ]))

    /// 「＋ 議題」の丸い札: 発言の背景（ポインタが乗ったときの薄い灰色）の左の外。窓が狭くて入らなければ内側へずらす
    private func gapMarker(_ r: CGRect) -> CGRect {
        let width = gapMarkerWidth, right = column.x - TranscriptMetrics.pad.width - 6
        return CGRect(x: max(4, right - width), y: (r.midY - 9).rounded(), width: width, height: 18)
    }

    private var gapMarkerWidth: CGFloat { CTLineGetTypographicBounds(gapLabel, nil, nil, nil) + 14 }

    /// 見出し: 議題は大きく右に細い線、小見出しは少し小さく
    private func drawHeadings(_ row: Row, in ctx: CGContext) {
        for h in row.headings {
            ctx.setFillColor((h.heading.title.isEmpty ? NSColor.tertiaryLabelColor : h.heading.level == 1 ? NSColor.labelColor : NSColor.secondaryLabelColor).cgColor)
            ctx.textPosition = CGPoint(x: h.rect.minX, y: h.baseline)
            CTLineDraw(h.line, ctx)
            if h.heading.level == 1, h.rect.maxX > h.rect.minX + h.textWidth + 24 {
                ctx.setFillColor(NSColor.separatorColor.cgColor)
                ctx.fill(CGRect(x: h.rect.minX + h.textWidth + 12, y: (h.baseline - 6).rounded(), width: h.rect.maxX - h.rect.minX - h.textWidth - 12, height: 1))
            }
        }
    }

    /// ブックマークの印（しおりの形）。filled でなければ、付けられることを示す薄い輪郭
    private func drawBookmark(in gutter: CGRect, filled: Bool, ctx: CGContext) {
        let w: CGFloat = 9, h: CGFloat = 12, x = gutter.maxX - 17, y = gutter.midY - h / 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x, y: y + h))
        path.addLine(to: CGPoint(x: x, y: y + 1.5))
        path.addQuadCurve(to: CGPoint(x: x + 1.5, y: y), control: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: x + w - 1.5, y: y))
        path.addQuadCurve(to: CGPoint(x: x + w, y: y + 1.5), control: CGPoint(x: x + w, y: y))
        path.addLine(to: CGPoint(x: x + w, y: y + h))
        path.addLine(to: CGPoint(x: x + w / 2, y: y + h - 3.5))
        path.closeSubpath()
        ctx.addPath(path)
        if filled {
            ctx.setFillColor(NSColor.controlAccentColor.cgColor)
            ctx.fillPath()
        } else {
            ctx.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
            ctx.setLineWidth(1.2)
            ctx.strokePath()
        }
    }

    /// コメントの印の所（ハイライトの最後の行の右上）
    private func commentMark(after last: CGRect) -> CGRect {
        CGRect(x: last.maxX + 2, y: last.minY - 5, width: 11, height: 10)
    }

    /// コメントの印（小さな吹き出し）
    private func drawCommentMark(in r: CGRect, color: NSColor, ctx: CGContext) {
        let path = CGMutablePath()
        path.addRoundedRect(in: CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height - 3), cornerWidth: 2.5, cornerHeight: 2.5)
        path.move(to: CGPoint(x: r.minX + 2.5, y: r.maxY - 3.5))
        path.addLine(to: CGPoint(x: r.minX + 2.5, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX + 6, y: r.maxY - 3.5))
        ctx.addPath(path)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
    }

    // MARK: 位置の変換

    /// 背景の下端が y より下にある最初の発言（なければ発言の数）
    private func firstRow(atOrBelow y: CGFloat) -> Int {
        var lo = 0, hi = rows.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if rows[mid].background.maxY < y { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// 点がある発言（背景と左の余白の印の所。見出しや発言の間、省いた発言は含めない）
    private func block(at p: CGPoint) -> Int? {
        let b = firstRow(atOrBelow: p.y)
        return b < rows.count && !rows[b].hidden && (rows[b].background.contains(p) || rows[b].gutter.contains(p)) ? b : nil
    }

    /// 発言 b の上端（見出しがあれば見出しの上端）
    private func contentTop(_ b: Int) -> CGFloat { rows[b].headings.first?.rect.minY ?? rows[b].frame.minY }

    /// 発言 b の前の、議題を入れる所: 前の発言の下端から b の上端までの間（最初の発言なら上の余白）。省いた発言は飛ばす
    private func gapRect(before b: Int) -> CGRect? {
        guard rows.indices.contains(b), !rows[b].hidden else { return nil }
        let col = column, bottom = contentTop(b) - 3
        let top = (rows[..<b].last(where: { !$0.hidden })?.frame.maxY ?? contentTop(b) - 22) + 3
        // 左は「＋ 議題」の札（発言の背景の左の外）まで、右は発言の背景の右端まで
        let left = max(0, col.x - TranscriptMetrics.pad.width - 6 - gapMarkerWidth), right = col.x + col.width + TranscriptMetrics.pad.width
        return bottom - top >= 8 ? CGRect(x: left, y: top, width: right - left, height: bottom - top) : nil
    }

    /// 点がある、議題を入れる所（その後の発言の番号）
    private func gap(at p: CGPoint) -> Int? {
        var b = firstRow(atOrBelow: p.y)
        while b < rows.count, rows[b].hidden || contentTop(b) <= p.y { b += 1 }
        guard let r = gapRect(before: b), r.contains(p) else { return nil }
        return b
    }

    /// 点がある見出し
    private func heading(at p: CGPoint) -> ResolvedNotes.Heading? {
        let b = firstRow(atOrBelow: p.y)
        guard b < rows.count else { return nil }
        return rows[b].headings.first { $0.rect.contains(p) }?.heading
    }

    /// 点の真下にある語（全体の番号。見比べは左の原文の語も）
    private func word(at p: CGPoint, in b: Int) -> Int? {
        let row = rows[b]
        var bodies = [(row.body, row.bodyOrigin, row.words)]
        if let o = row.original { bodies.append((o.body, o.origin, o.words)) }
        for (body, origin, words) in bodies {
            if let c = body.character(at: CGPoint(x: p.x - origin.x, y: p.y - origin.y)),
               let local = words.firstIndex(where: { NSLocationInRange(c, $0) }) {
                return document.blocks[b].words.lowerBound + local
            }
        }
        return nil
    }

    /// 語 w にかかるハイライト（重なっていれば後から付けたもの）
    private func highlight(at w: Int) -> ResolvedNotes.Highlight? {
        highlights.last { $0.words.contains(w) }
    }

    /// 点にあるコメントの印
    private func commentMark(at p: CGPoint, in b: Int) -> ResolvedNotes.Highlight? {
        let row = rows[b], range = document.blocks[b].words
        for h in highlights where !h.comment.isEmpty && range.contains(h.words.upperBound) {
            let lo = max(h.words.lowerBound, range.lowerBound), hi = h.words.upperBound
            let a = row.words[lo - range.lowerBound], z = row.words[hi - range.lowerBound]
            if let last = row.body.rects(for: NSRange(location: a.location, length: NSMaxRange(z) - a.location)).last,
               commentMark(after: last.offsetBy(dx: row.bodyOrigin.x, dy: row.bodyOrigin.y)).insetBy(dx: -4, dy: -4).contains(p) { return h }
        }
        return nil
    }

    /// 点に一番近い本文の位置。見出しかその上なら発言の頭、本文より下（発言の間）なら発言の終わり
    private func position(at p: CGPoint) -> TextPosition? {
        guard !rows.isEmpty else { return nil }
        let b = min(firstRow(atOrBelow: p.y), rows.count - 1), row = rows[b]
        if p.y < row.bodyOrigin.y { return TextPosition(block: b, offset: 0) }
        if p.y > row.bodyOrigin.y + row.body.height { return TextPosition(block: b, offset: row.body.length) }
        return TextPosition(block: b, offset: row.body.caret(at: CGPoint(x: p.x - row.bodyOrigin.x, y: p.y - row.bodyOrigin.y)))
    }

    /// 発言 b の本文のうち選択している範囲
    private func selectedRange(in b: Int) -> NSRange? {
        guard let s = selection, rows.indices.contains(b) else { return nil }
        let (from, to) = (min(s.anchor, s.head), max(s.anchor, s.head))
        guard from < to, (from.block...to.block).contains(b) else { return nil }
        let start = b == from.block ? from.offset : 0, end = b == to.block ? to.offset : rows[b].body.length
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    /// 選択にかかっている語（全体の番号。語の一部でも選んでいればその語を含める）
    private func selectedWords() -> ClosedRange<Int>? {
        guard let s = selection else { return nil }
        let (from, to) = (min(s.anchor, s.head), max(s.anchor, s.head))
        var first: Int?, last: Int?
        for b in from.block...to.block {
            guard let r = selectedRange(in: b) else { continue }
            let lower = document.blocks[b].words.lowerBound
            if first == nil, let i = rows[b].words.firstIndex(where: { NSMaxRange($0) > r.location }) { first = lower + i }
            if let i = rows[b].words.lastIndex(where: { $0.location < NSMaxRange(r) }) { last = lower + i }
        }
        guard let first, let last, first <= last else { return nil }
        return first...last
    }

    // MARK: ポインタ

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                           owner: self))
        }
    }

    /// カーソルは矢印（話者名・見出し・ブックマークの印の上は指）
    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: .arrow)
        var b = firstRow(atOrBelow: visibleRect.minY)
        while b < rows.count, (rows[b].headings.first?.rect.minY ?? rows[b].frame.minY) <= visibleRect.maxY {
            defer { b += 1 }
            guard !rows[b].hidden else { continue }
            for name in rows[b].nameRects { addCursorRect(name, cursor: .pointingHand) }
            addCursorRect(rows[b].gutter, cursor: .pointingHand)
            for h in rows[b].headings { addCursorRect(CGRect(x: h.rect.minX, y: h.rect.minY, width: h.textWidth + 8, height: h.rect.height), cursor: .pointingHand) }
            if let gap = gapRect(before: b) { addCursorRect(gap, cursor: .pointingHand) }
        }
    }

    override func mouseMoved(with event: NSEvent) { hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hover(at: nil) }

    /// ポインタの下の発言と語の印、発言と発言の間（議題を入れる所）の印を付け替える（変わった所だけ描き直す）。ドラッグ中は付けない
    private func hover(at point: CGPoint?) {
        let gap = dragging ? nil : point.flatMap { visibleRect.contains($0) ? self.gap(at: $0) : nil }
        if gap != hoveredGap {
            let old = hoveredGap
            hoveredGap = gap
            for b in [old, gap].compactMap({ $0 }) { if let r = gapRect(before: b) { redraw(r.insetBy(dx: -2, dy: -2)) } }
        }
        let new: (block: Int, word: Int?, onName: Bool)? = dragging || gap != nil ? nil : point.flatMap { p in
            guard visibleRect.contains(p), let b = block(at: p) else { return nil }
            let onName = rows[b].nameRects.contains { $0.contains(p) }
            return (b, onName ? nil : word(at: p, in: b), onName)
        }
        let old = hovered
        guard new?.block != old?.block || new?.word != old?.word || new?.onName != old?.onName else { return }
        hovered = new
        for b in Set([old?.block, new?.block].compactMap { $0 }) { redraw(block: b) }
    }

    /// スクロールしたら、帯を置き直し、見えている最初の発言を知らせ、ポインタの下の発言を選び直す
    @objc private func clipMoved() {
        placeTiles()
        if let clip = enclosingScrollView?.contentView, !rows.isEmpty { events.visible(min(firstRow(atOrBelow: clip.bounds.minY), rows.count - 1)) }
        guard let window, window.isKeyWindow else { return }
        hover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    // MARK: クリック・ドラッグ・選択

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        press = (p, event.clickCount)
        dragging = false
        if event.modifierFlags.contains(.shift), let s = selection, let head = position(at: p) {
            dragging = true  // shift を押しながらのクリック・ドラッグで選択を広げる
            select(s.anchor, head)
        } else if event.clickCount == 2, let b = block(at: p) {
            dragging = true  // ダブルクリックで発言を選ぶ
            select(TextPosition(block: b, offset: 0), TextPosition(block: b, offset: rows[b].body.length))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !dragging {
            guard hypot(p.x - press.point.x, p.y - press.point.y) > 3, let anchor = position(at: press.point) else { return }
            dragging = true
            hover(at: nil)
            toolbar?.isHidden = true
            selection = (anchor, anchor)
        }
        guard let anchor = selection?.anchor, let head = position(at: p) else { return }
        select(anchor, head)
        autoscroll(with: event)
        // ポインタが見えている範囲の上下の外にある間は、マウスを動かさなくても送り続ける
        if visibleRect.contains(CGPoint(x: visibleRect.midX, y: p.y)) {
            stopAutoscroll()
        } else if autoscrollTimer == nil {
            autoscrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.autoscrollStep() }
            }
        }
    }

    private func autoscrollStep() {
        guard dragging, let window, let anchor = selection?.anchor else { return stopAutoscroll() }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil), visible = visibleRect
        let over = p.y < visible.minY ? p.y - visible.minY : p.y > visible.maxY ? p.y - visible.maxY : 0
        guard over != 0 else { return stopAutoscroll() }
        scroll(NSPoint(x: visible.minX, y: visible.minY + max(-40, min(40, over))))
        if let head = position(at: p) { select(anchor, head) }
    }

    private func stopAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            press = nil
            dragging = false
            stopAutoscroll()
            placeToolbar()
            hover(at: convert(event.locationInWindow, from: nil))
        }
        guard let press, !dragging, press.clicks == 1 else { return }
        clearSelection()
        click(at: press.point)
    }

    /// クリック: 見出しなら名前の変更、発言と発言の間なら議題を入れる、左の余白ならブックマーク、話者名なら名前の変更と絞り込み、コメントの印ならコメント、
    /// 語ならその語から再生、発言の余白なら発言の頭から再生
    private func click(at p: CGPoint) {
        if let h = heading(at: p) { return editHeading(h) }
        if let b = gap(at: p), let r = gapRect(before: b) { return addHeading(before: b, level: 1, at: gapMarker(r)) }
        guard let b = block(at: p) else { return }
        if rows[b].gutter.contains(p) {
            events.edit(.bookmark(block: b))
        } else if let name = rows[b].nameRects.first(where: { $0.contains(p) }) {
            showSpeakerMenu(block: b, at: name)
        } else if let h = commentMark(at: p, in: b) {
            editHighlight(h, at: CGRect(origin: p, size: .zero))
        } else if let w = word(at: p, in: b) {
            player.seek(to: document.words[w].start, play: true)
        } else {
            player.seek(to: document.blocks[b].start, play: true)
        }
    }

    private func select(_ anchor: TextPosition, _ head: TextPosition) {
        selection = (anchor, head)
        redrawAll()
    }

    func clearSelection() {
        guard selection != nil else { return }
        selection = nil
        redrawAll()
        placeToolbar()
    }

    /// 選択のすぐ上（上に余裕がなければ下）に、ハイライト・コメント・見出し・コピーのバーを出す
    private func placeToolbar() {
        guard !dragging, let s = selection, s.anchor != s.head, let words = selectedWords() else {
            toolbar?.isHidden = true
            return
        }
        let content = SelectionToolbar(key: words) { [weak self] in self?.run($0, on: words) }
        let bar: NSHostingView<SelectionToolbar>
        if let toolbar {
            bar = toolbar
            bar.rootView = content
        } else {
            bar = NSHostingView(rootView: content)
            addSubview(bar)
            toolbar = bar
        }
        let (from, to) = (min(s.anchor, s.head), max(s.anchor, s.head)), size = bar.fittingSize
        let first = selectionRect(block: from.block, first: true), last = selectionRect(block: to.block, first: false)
        let visible = visibleRect, col = column
        var y = (first?.minY ?? visible.minY + 60) - size.height - 8
        if y < visible.minY + 4 { y = min(visible.maxY - size.height - 8, (last?.maxY ?? visible.minY) + 8) }
        let x = min(max(col.x, (first?.minX ?? col.x) - 8), col.x + col.width - size.width)
        bar.frame = CGRect(x: x, y: max(visible.minY + 4, y), width: size.width, height: size.height)
        bar.isHidden = false
    }

    /// 選択の最初（または最後）の行の矩形
    private func selectionRect(block b: Int, first: Bool) -> CGRect? {
        guard let r = selectedRange(in: b) else { return nil }
        let rects = rows[b].body.rects(for: r)
        return (first ? rects.first : rects.last)?.offsetBy(dx: rows[b].bodyOrigin.x, dy: rows[b].bodyOrigin.y)
    }

    private func run(_ action: SelectionToolbar.Action, on words: ClosedRange<Int>) {
        let anchor = toolbar?.frame ?? .zero
        switch action {
        case .highlight(let color):
            events.edit(.highlight(words: words, color: color, comment: ""))
            clearSelection()
        case .comment:
            let edit = events.edit
            showPopover(at: anchor) { close in
                CommentPopover(text: "", color: 0, isNew: true, save: { edit(.highlight(words: words, color: $1, comment: $0)) }, delete: nil, close: close)
            }
            clearSelection()
        case .heading:
            // 見出しは、選んだ所を含む文の前に入れる（発言の途中なら、そこで発言を分ける）。
            // 名前は、最初の発言の選んだ部分（話題を表す言葉を選んで「見出し」を押せば、それが名前になる）
            let b = document.words[words.lowerBound].block
            let title = selectedRange(in: b).map { (document.text(of: b) as NSString).substring(with: $0) }?
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) ?? ""
            addHeading(beforeWord: document.sentenceStart(of: words.lowerBound), level: 1, at: anchor, title: String(title.prefix(40)))
            clearSelection()
        case .copy:
            copySelection()
        case .clear:
            clearSelection()
        }
    }

    /// コピーする文字（書式なし）。1 つの発言の一部なら選んだ文字だけ。
    /// 発言をまたぐか発言をまるごと選んだときは、発言ごとに「[時刻] 名前」の行と本文を空行で区切って並べ、頭から選んだ発言の前の見出しも入れる
    func selectedText() -> String? {
        guard let s = selection else { return nil }
        let (from, to) = (min(s.anchor, s.head), max(s.anchor, s.head))
        var parts: [(block: Int, text: String, range: NSRange, whole: Bool)] = []
        for b in from.block...to.block {
            guard let r = selectedRange(in: b) else { continue }
            let text = document.text(of: b) as NSString
            parts.append((b, text.substring(with: r), r, r.length == text.length))
        }
        guard !parts.isEmpty else { return nil }
        if parts.count == 1, !parts[0].whole { return parts[0].text }
        return parts.map { part in
            let block = document.blocks[part.block]
            let headings = part.range.location == 0 ? block.headings.map { ($0.level == 1 ? "# " : "## ") + $0.title + "\n\n" }.joined() : ""
            return headings + "[\(formatTime(block.start))] \(block.name)\n\(part.text)"
        }
        .joined(separator: "\n\n") + "\n"
    }

    @discardableResult
    func copySelection() -> Bool {
        guard let text = selectedText() else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    @objc func copy(_ sender: Any?) { copySelection() }

    override func selectAll(_ sender: Any?) {
        guard let last = rows.indices.last else { return }
        select(TextPosition(block: 0, offset: 0), TextPosition(block: last, offset: rows[last].body.length))
        placeToolbar()
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): selectedText() != nil
        case #selector(selectAll(_:)): !rows.isEmpty
        default: true
        }
    }

    // MARK: 注釈の小窓とメニュー

    private func showPopover<Content: View>(at rect: CGRect, _ content: (@escaping () -> Void) -> Content) {
        let popover = NSPopover()
        popover.behavior = .transient
        let controller = NSHostingController(rootView: content { [weak popover] in popover?.performClose(nil) })
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
        popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
    }

    /// ハイライトの色・コメントを変える小窓
    private func editHighlight(_ h: ResolvedNotes.Highlight, at rect: CGRect) {
        let edit = events.edit
        showPopover(at: rect) { close in
            CommentPopover(text: h.comment, color: h.color, isNew: false, save: { text, color in
                if text != h.comment { edit(.comment(h.id, text)) }
                if color != h.color { edit(.recolor(h.id, color)) }
            }, delete: { edit(.delete(h.id)) }, close: close)
        }
    }

    /// 見出しの名前・段を変える小窓
    private func editHeading(_ h: ResolvedNotes.Heading) {
        guard let b = rows.indices.first(where: { rows[$0].headings.contains { $0.heading.id == h.id } }),
              let line = rows[b].headings.first(where: { $0.heading.id == h.id }) else { return }
        let edit = events.edit
        showPopover(at: CGRect(x: line.rect.minX, y: line.rect.minY, width: line.textWidth, height: line.rect.height)) { close in
            HeadingPopover(title: h.title, level: h.level, isNew: false, save: { edit(.editHeading(h.id, level: $1, title: $0)) },
                           delete: { edit(.delete(h.id)) }, close: close)
        }
    }

    /// 発言 b の前に見出しを入れる小窓
    /// 語 w の前に見出しを入れる小窓（発言の頭なら発言の前、途中ならそこで発言を分ける）
    private func addHeading(beforeWord w: Int, level: Int, at rect: CGRect, title: String = "") {
        let b = document.words[w].block, atStart = w == document.blocks[b].words.lowerBound, edit = events.edit
        showPopover(at: rect) { close in
            HeadingPopover(title: title, level: level, isNew: true, save: {
                edit(atStart ? .heading(block: b, level: $1, title: $0) : .headingAt(word: w, level: $1, title: $0))
            }, delete: nil, close: close)
        }
    }

    private func addHeading(before b: Int, level: Int, at rect: CGRect) {
        let edit = events.edit
        showPopover(at: rect) { close in
            HeadingPopover(title: "", level: level, isNew: true, save: { edit(.heading(block: b, level: $1, title: $0)) }, delete: nil, close: close)
        }
    }

    private func showSpeakerMenu(block b: Int, at rect: CGRect) {
        let speaker = document.blocks[b].speaker, events = events
        showPopover(at: rect) { close in
            SpeakerPopover(name: document.blocks[b].name, filtered: filter == speaker,
                           rename: { events.rename(speaker, $0) }, filter: { events.filter($0 ? speaker : nil) }, close: close)
        }
    }

    /// 右クリック: ハイライトの色・コメント・削除、選んだ所のコピー、発言のコピー・再生・ブックマーク・見出し
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(), p = convert(event.locationInWindow, from: nil), edit = events.edit
        if let h = heading(at: p) {
            menu.addItem(item("見出しを編集…") { [weak self] in self?.editHeading(h) })
            menu.addItem(item("見出しを削除") { edit(.delete(h.id)) })
            return menu
        }
        if let b = block(at: p), let w = word(at: p, in: b), let h = highlight(at: w) {
            for i in 0..<HighlightColor.count {
                let color = item(HighlightColor.name(i)) { edit(.recolor(h.id, i)) }
                color.state = h.color == i ? .on : .off
                color.image = swatch(i)
                menu.addItem(color)
            }
            menu.addItem(item(h.comment.isEmpty ? "コメントを付ける…" : "コメントを編集…") { [weak self] in
                self?.editHighlight(h, at: CGRect(origin: p, size: .zero))
            })
            menu.addItem(item("ハイライトを削除") { edit(.delete(h.id)) })
            menu.addItem(.separator())
        }
        if selectedText() != nil { menu.addItem(item("コピー") { [weak self] in self?.copySelection() }) }
        if let b = block(at: p) {
            let block = document.blocks[b], text = document.text(of: b), rect = CGRect(origin: p, size: .zero)
            if !menu.items.isEmpty, menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
            menu.addItem(item("この発言をコピー") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("[\(formatTime(block.start))] \(block.name)\n\(text)\n", forType: .string)
            })
            menu.addItem(item("この発言から再生") { [player] in player.seek(to: block.start, play: true) })
            menu.addItem(.separator())
            menu.addItem(item(bookmarks[b] == nil ? "ブックマーク" : "ブックマークを外す") { edit(.bookmark(block: b)) })
            menu.addItem(item("この発言の前に議題を入れる…") { [weak self] in self?.addHeading(before: b, level: 1, at: rect) })
            menu.addItem(item("この発言の前に小見出しを入れる…") { [weak self] in self?.addHeading(before: b, level: 2, at: rect) })
            // 発言の途中の文なら、その文の前で発言を分けて見出しを入れる（1 人が長く話すときの話題の切り替わり）
            if let w = word(at: p, in: b), case let s = document.sentenceStart(of: w), s > block.words.lowerBound {
                menu.addItem(item("この文の前で分けて議題を入れる…") { [weak self] in self?.addHeading(beforeWord: s, level: 1, at: rect) })
                menu.addItem(item("この文の前で分けて小見出しを入れる…") { [weak self] in self?.addHeading(beforeWord: s, level: 2, at: rect) })
            }
        }
        return menu.items.isEmpty ? nil : menu
    }

    private func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runMenuItem), keyEquivalent: "")
        item.target = self
        item.representedObject = action
        return item
    }

    @objc private func runMenuItem(_ item: NSMenuItem) { (item.representedObject as? () -> Void)?() }

    /// メニューに出す色見本
    private func swatch(_ i: Int) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            HighlightColor.solid[i].setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    /// Space で再生・一時停止、←→ で 5 秒戻る・進む、B で発言（選んでいればその発言、なければ今の発言）をブックマーク、esc で選択を解除
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            switch event.keyCode {
            case 49: player.toggle(); return
            case 123: player.skip(-5); return
            case 124: player.skip(5); return
            case 53: clearSelection(); return
            case 11:
                let b = selection.map { min($0.anchor, $0.head).block } ?? now ?? player.shownBlock
                if let b { events.edit(.bookmark(block: b)) }
                return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        redrawAll()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self)
        guard let window, let scroll = enclosingScrollView else { return }
        center.addObserver(self, selector: #selector(userScrolled), name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.postsBoundsChangedNotifications = true
        center.addObserver(self, selector: #selector(clipMoved), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        // 窓が前に出た・後ろに回ったら、選択の色（強調・控えめ）を変える
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            center.addObserver(self, selector: #selector(keyChanged), name: name, object: window)
        }
        placeTiles()
    }

    @objc private func userScrolled() { events.userScrolled() }
    @objc private func keyChanged() { if selection != nil { redrawAll() } }

    // MARK: 印（検索の一致・絞り込み）

    func mark(filter: String?, hits: Set<Int>, active: [Int]) {
        if filter != self.filter {
            self.filter = filter
            redrawAll()
        }
        guard hits != self.hits || active != self.active else { return }
        let changed = self.hits.symmetricDifference(hits).union(self.active).union(active)
        self.hits = hits
        self.active = active
        changed.forEach(redraw(word:))
        if let w = active.first, document.words.indices.contains(w) { reveal(document.words[w].block, anchor: 0.4) }
    }

    private func redraw(word w: Int) {
        guard document.words.indices.contains(w) else { return }
        let b = document.words[w].block, local = w - document.blocks[b].words.lowerBound
        guard rows.indices.contains(b), rows[b].words.indices.contains(local) else { return }
        var rects = span(rows[b].words, local, local, in: rows[b].body, at: rows[b].bodyOrigin)
        if let o = rows[b].original { rects += span(o.words, local, local, in: o.body, at: o.origin) }
        for r in rects { redraw(r.insetBy(dx: -4, dy: -4)) }
    }

    private func redraw(block b: Int) {
        if rows.indices.contains(b) { redraw(rows[b].background.union(rows[b].gutter).insetBy(dx: -2, dy: -2)) }
    }

    // MARK: 再生に合わせる

    /// 再生中の語・発言が変わるたびに印を付け替え、追いかけている間は今の発言が見える位置へ送る
    private func observePlayer() {
        let (word, block, playing, shown, spokenWord) = withObservationTracking {
            (player.currentWord, player.currentBlock, player.isPlaying, player.shownBlock, player.spokenWord)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePlayer() }
        }
        let immersive = document.immersive
        if word != nowWord {
            let old = nowWord
            nowWord = word
            [old, word].compactMap { $0 }.forEach(redraw(word:))
        }
        defer { wasPlaying = playing }
        // 没入モード: 話し終えた所が進んだら今の発言を描き直し、前に出す発言が変わったら送る（止まっていても）
        if spokenWord != spoken {
            spoken = spokenWord
            if immersive, let focus { redraw(block: focus) }
        }
        if shown != focus {
            let old = focus
            focus = shown
            if immersive {
                // 前と今の発言の間の発言も、済んだ・これからが入れ替わるので描き直す
                let changed = [old, shown].compactMap { $0 }.filter(rows.indices.contains)
                if let lo = changed.min(), let hi = changed.max() {
                    redraw(rows[lo].background.union(rows[hi].background).union(rows[lo].gutter).insetBy(dx: -2, dy: -2))
                }
                if following, let shown { reveal(shown, anchor: TranscriptMetrics.immersiveAnchor) }
            }
        }
        if block != now {
            let old = now
            now = block
            [old, block].compactMap { $0 }.forEach(redraw(block:))
            if !immersive, following, playing, let block { reveal(block) }
        } else if playing, !wasPlaying, following, let b = immersive ? shown : block, !isVisible(b) {
            reveal(b, anchor: immersive ? TranscriptMetrics.immersiveAnchor : 0.25)  // 再生を始めたとき、今の発言が見えていなければ送る
        } else if following, playing, let word, let block, rows.indices.contains(block), let clip = enclosingScrollView?.contentView {
            // 長い発言は、読んでいる行が画面の下の方に来たら送る
            let row = rows[block], local = word - document.blocks[block].words.lowerBound
            if row.words.indices.contains(local), let r = row.body.rects(for: row.words[local]).first,
               row.bodyOrigin.y + r.maxY > clip.bounds.maxY - clip.bounds.height * 0.2 {
                scroll(toY: row.bodyOrigin.y + r.minY - clip.bounds.height * 0.3)
            }
        }
    }

    func recall(_ n: Int) {
        guard n != recalled else { return }
        recalled = n
        if document.immersive, let focus { reveal(focus, anchor: TranscriptMetrics.immersiveAnchor) } else if let b = now { reveal(b) }
    }

    /// 発言 b（見出しがあれば見出し）の中の位置 fraction（0 は先頭）が、画面の上から anchor の位置に来るように送る。
    /// まだ並べていない（窓の大きさが決まっていない）ときは、並べ終わってから送る
    func reveal(_ b: Int, at fraction: CGFloat = 0, anchor: CGFloat = 0.25) {
        guard laidOutWidth > 0, rows.indices.contains(b), let clip = enclosingScrollView?.contentView, clip.bounds.height > 0 else {
            pendingReveal = (b, fraction, anchor)
            return
        }
        let frame = rows[b].background, top = rows[b].headings.first?.rect.minY ?? frame.minY
        scroll(toY: (fraction == 0 ? top : frame.minY + frame.height * fraction) - clip.bounds.height * anchor)
    }

    private func isVisible(_ b: Int) -> Bool {
        guard rows.indices.contains(b), let clip = enclosingScrollView?.contentView else { return false }
        let frame = rows[b].frame
        return frame.minY >= clip.bounds.minY && frame.minY < clip.bounds.maxY - 40
    }

    private func scroll(toY y: CGFloat) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let target = NSPoint(x: 0, y: min(max(0, y), max(0, frame.height - clip.bounds.height)))
        guard abs(target.y - clip.bounds.origin.y) > 1 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.4
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clip.animator().setBoundsOrigin(target)
        }
    }

    private var isNearBottom: Bool {
        guard let clip = enclosingScrollView?.contentView else { return true }
        return frame.height - clip.bounds.maxY < 160
    }

    #if DEBUG
    /// 開発用: 発言 b の本文の文字 offset の中央の点（本文の長さなら最後の文字の右端）
    func debugPoint(block b: Int, offset: Int) -> CGPoint? {
        guard rows.indices.contains(b), rows[b].body.length > 0 else { return nil }
        let row = rows[b], o = min(max(0, offset), row.body.length - 1)
        guard let r = row.body.rects(for: NSRange(location: o, length: 1)).first else { return nil }
        return CGPoint(x: row.bodyOrigin.x + (offset >= row.body.length ? r.maxX - 1 : r.midX), y: row.bodyOrigin.y + r.midY)
    }

    /// 開発用: 時刻 t の発言が上端（没入モードは上から 3 割）に来るまで、動きを付けずに送る
    func debugScroll(to t: Double) {
        guard let b = document.blocks.lastIndex(where: { $0.start <= t }), rows.indices.contains(b), let scroll = enclosingScrollView else { return }
        let offset = document.immersive ? scroll.contentView.bounds.height * TranscriptMetrics.immersiveAnchor : 40
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: max(0, rows[b].frame.minY - offset)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// 開発用: 発言 b の前の、議題を入れる所の点
    func debugGapPoint(block b: Int) -> CGPoint? {
        gapRect(before: b).map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    /// 開発用: 発言 b の見出しの左の余白の点（発言単位の選択を始める所）
    func debugHeaderPoint(block b: Int) -> CGPoint? {
        rows.indices.contains(b) ? CGPoint(x: rows[b].frame.minX + 4, y: rows[b].frame.minY + 8) : nil
    }
    #endif
}

/// 一覧の帯 1 枚（高さ 512 の CALayer）。自分の範囲を、一覧の座標に合わせて一覧に描かせる。
/// NSView ではなくレイヤーにして、AppKit の描き直しの仕組みの外に置く（スクロールで見えるようになった所を
/// AppKit が毎フレーム描き直させるのを避ける。帯は見えている所の前後も描いてあるので要らない）
nonisolated private final class TileLayer: CALayer {
    nonisolated(unsafe) weak var list: TranscriptListView?

    override init() {
        super.init()
        needsDisplayOnBoundsChange = false
        actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]  // 描き直しをふわっと切り替えない
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(in ctx: CGContext) {
        if !contentsAreFlipped() {  // 上から下の座標にする
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        let origin = frame.origin, dirty = ctx.boundingBoxOfClipPath.offsetBy(dx: origin.x, dy: origin.y)
        ctx.translateBy(x: -origin.x, y: -origin.y)
        nonisolated(unsafe) let context = ctx
        let list = list
        MainActor.assumeIsolated {  // 描くのはメインスレッド（Core Animation のコミット）
            guard let list else { return }
            list.effectiveAppearance.performAsCurrentDrawingAppearance { list.drawContent(dirty, in: context) }
        }
    }
}
