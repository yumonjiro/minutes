import AppKit
import CoreText

/// Core Text で幅に合わせて折り返して並べた文章（1 段落）。行の位置を持ち、座標と文字の位置の変換、範囲の矩形、描画をする。
/// 行の高さはどの行も同じ（日本語のフォントの高さに合わせる）。文字の色は描くときの塗りの色を使うので、外観を切り替えても作り直さなくてよい
nonisolated struct TextLayout {
    struct Line {
        let line: CTLine
        /// 文字の範囲（UTF-16）
        let range: NSRange
        /// 行の上端（この文章の上端から）
        let top: CGFloat
    }

    let lines: [Line]
    let length: Int
    /// ベースラインまでの高さ・文字の高さ（上端から下端）・行の送り（行間を含む）
    let ascent: CGFloat, glyphHeight: CGFloat, lineHeight: CGFloat

    init(_ text: String, font: NSFont, width: CGFloat, lineSpacing: CGFloat) {
        let string = NSAttributedString(string: text, attributes: [
            .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
        let metrics = Self.metrics(font)
        ascent = metrics.ascent
        glyphHeight = metrics.height
        lineHeight = ceil(metrics.height) + lineSpacing
        length = string.length
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        var lines: [Line] = [], start = 0
        while start < length {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(max(width, 1))))
            lines.append(Line(line: CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)),
                              range: NSRange(location: start, length: count), top: CGFloat(lines.count) * lineHeight))
            start += count
        }
        self.lines = lines
    }

    /// 文章の高さ（最後の行の下の行間は含めない）
    var height: CGFloat { lines.isEmpty ? 0 : lines.last!.top + ceil(glyphHeight) }

    /// 日本語（ヒラギノ）と英字が混ざっても同じになるよう、両方を含む文字で測る
    private static func metrics(_ font: NSFont) -> (ascent: CGFloat, height: CGFloat) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "あA", attributes: [.font: font]))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return (ascent, ascent + descent)
    }

    private func lineIndex(at y: CGFloat) -> Int {
        min(max(0, Int(floor(y / lineHeight))), lines.count - 1)
    }

    private func offset(_ line: Line, _ index: Int) -> CGFloat {
        CTLineGetOffsetForStringIndex(line.line, index, nil)
    }

    /// 点（この文章の左上から）に一番近い、文字と文字の間の位置（0...length）。上にはみ出せば先頭、下なら末尾
    func caret(at p: CGPoint) -> Int {
        guard !lines.isEmpty, p.y >= 0 else { return 0 }
        guard p.y < height else { return length }
        let line = lines[lineIndex(at: p.y)]
        let i = CTLineGetStringIndexForPosition(line.line, CGPoint(x: p.x, y: 0))
        return i == kCFNotFound ? line.range.location : min(max(i, line.range.location), NSMaxRange(line.range))
    }

    /// 点の真下にある文字（なければ nil）
    func character(at p: CGPoint) -> Int? {
        guard !lines.isEmpty, p.y >= 0, p.y < height else { return nil }
        let line = lines[lineIndex(at: p.y)]
        guard p.y - line.top <= glyphHeight + 2, p.x >= 0, p.x <= offset(line, NSMaxRange(line.range)) else { return nil }
        let caret = CTLineGetStringIndexForPosition(line.line, CGPoint(x: p.x, y: 0))
        guard caret != kCFNotFound else { return nil }
        let c = p.x < offset(line, caret) ? caret - 1 : caret
        return min(max(c, line.range.location), NSMaxRange(line.range) - 1)
    }

    /// 文字の範囲を囲む矩形（行ごと。高さは文字の高さ）
    func rects(for range: NSRange) -> [CGRect] {
        lines.compactMap { line in
            let r = NSIntersectionRange(range, line.range)
            guard r.length > 0 else { return nil }
            let x0 = offset(line, r.location), x1 = offset(line, NSMaxRange(r))
            return CGRect(x: x0, y: line.top, width: x1 - x0, height: glyphHeight)
        }
    }

    /// 描く（文字の色は今の塗りの色）。origin は文章の左上、visible の外の行は描かない。
    /// 呼ぶ側で上下を反転した座標（isFlipped の表示）と、文字を正立させる textMatrix にしておく
    func draw(in ctx: CGContext, at origin: CGPoint, visible: CGRect) {
        for line in lines where origin.y + line.top <= visible.maxY && origin.y + line.top + lineHeight >= visible.minY {
            ctx.textPosition = CGPoint(x: origin.x, y: origin.y + line.top + ascent)
            CTLineDraw(line.line, ctx)
        }
    }
}

extension CGContext {
    /// 上下を反転した表示（isFlipped）で Core Text の文字を正立させる
    func prepareForFlippedText() {
        textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    }

    func fillRoundedRect(_ rect: CGRect, radius: CGFloat, color: NSColor) {
        setFillColor(color.cgColor)
        let r = min(radius, rect.width / 2, rect.height / 2)
        addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
        fillPath()
    }
}
