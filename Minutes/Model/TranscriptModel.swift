import MinutesCore
import SwiftUI

/// 画面用の文字起こし: 同じ話者が続く発言を 1 つの吹き出しにまとめ、単語に通し番号を振る（Web 版の lib/transcript.ts と同じ）。
/// 見出しを入れた所では、同じ話者が続いていても吹き出しを分ける（1 人が長く話すポッドキャストなどで、話の途中に見出しを入れられるように）
struct TranscriptModel {
    struct Word: Equatable {
        let text: String
        let start: Double
        let end: Double
        fileprivate(set) var block: Int
        /// 文字起こしの発言（transcript.segments）の番号
        let segment: Int
    }

    struct Block: Identifiable {
        let id: Int
        let speaker: String
        var start: Double
        var end: Double
        var words: Range<Int>
    }

    /// 話者の色（ライト, ダーク）。青・橙・緑・紫・青緑・赤・黄土・赤紫の順で、話者が少ないときほど見分けやすい。
    /// OKLCH で明るさと鮮やかさをそろえ（ライトは L≈0.53、ダークは L≈0.78）、どの色も目立ちすぎない落ち着いた色にした。
    /// 話者名の文字として、今の発言の薄い背景の上でもコントラスト比 4.5:1 以上（WCAG AA）
    static let palette: [NSColor] = [
        (0x2f6bc2, 0x8ab9ff), (0xad5002, 0xf5a06f), (0x037e3f, 0x79cd91), (0x7d56b8, 0xc3a5f9),
        (0x047887, 0x3ecce2), (0xb5414d, 0xfb979a), (0x876904, 0xd7b355), (0xa84482, 0xee97c9),
    ].map { NSColor(light: $0, dark: $1) }

    /// 組み立て直すたびに変わる（描き直しが要るかを安く比べるため）
    let id = UUID()
    private(set) var blocks: [Block] = []
    private(set) var words: [Word] = []
    /// 文字起こしの発言（transcript.segments と同じ順）ごとの語の範囲
    private(set) var segments: [Range<Int>] = []
    /// 登場順
    let speakers: [String]
    let nsColors: [String: NSColor]
    var colors: [String: Color] { nsColors.mapValues { Color(nsColor: $0) } }
    /// 話者A, B, …
    let labels: [String: String]
    /// 話者分離の区間（文字起こしに登場する話者だけ）
    let turns: [Transcript.Turn]
    /// 話者ごとの発話時間（秒）
    let talk: [String: Double]

    /// splits: 見出しを入れた時刻（その語から吹き出しを分ける）
    init(_ t: Transcript, splits: [Double] = []) {
        for (i, seg) in t.segments.enumerated() {
            let first = words.count
            words += seg.words.map { Word(text: $0.w, start: $0.s, end: $0.e, block: 0, segment: i) }
            segments.append(first..<words.count)
        }
        // 見出しの時刻に始まる語（前後 0.05 秒）
        let all = words
        let cuts = Set(splits.compactMap { time in
            Self.firstWord(in: all, atOrAfter: time - 0.05).flatMap { abs(all[$0].start - time) <= 0.05 ? $0 : nil }
        })
        for (i, seg) in t.segments.enumerated() {
            let range = segments[i]
            if blocks.last?.speaker != seg.speaker {
                blocks.append(Block(id: blocks.count, speaker: seg.speaker, start: seg.start, end: seg.end, words: range.lowerBound..<range.lowerBound))
            }
            for w in range {
                if cuts.contains(w), !blocks[blocks.count - 1].words.isEmpty {
                    // 発言の途中なら、前の吹き出しはその前の語で終わり、次の吹き出しはこの語から始まる
                    let atSegmentStart = w == range.lowerBound
                    if !atSegmentStart { blocks[blocks.count - 1].end = words[w - 1].end }
                    blocks.append(Block(id: blocks.count, speaker: seg.speaker, start: atSegmentStart ? seg.start : words[w].start, end: seg.end,
                                        words: w..<w))
                }
                let b = blocks.count - 1
                words[w].block = b
                blocks[b].words = blocks[b].words.lowerBound..<w + 1
            }
            blocks[blocks.count - 1].end = seg.end
        }
        var seen: [String] = []
        for b in blocks where !seen.contains(b.speaker) { seen.append(b.speaker) }
        speakers = seen
        nsColors = Dictionary(uniqueKeysWithValues: seen.enumerated().map { ($1, Self.palette[$0 % Self.palette.count]) })
        labels = Dictionary(uniqueKeysWithValues: seen.enumerated().map { ($1, "話者" + String(UnicodeScalar(65 + $0)!)) })
        turns = t.diarization.filter { seen.contains($0.speaker) }
        // 発話時間は話者分離の区間から（重なって話した時間も含む）
        var talk = Dictionary(uniqueKeysWithValues: seen.map { ($0, 0.0) })
        if turns.isEmpty {
            for b in blocks { talk[b.speaker, default: 0] += b.end - b.start }
        } else {
            for d in turns { talk[d.speaker, default: 0] += d.end - d.start }
        }
        self.talk = talk
    }

    var duration: Double { blocks.last?.end ?? 0 }

    func text(of block: Block) -> String { words[block.words].map(\.text).joined() }

    /// 文字起こしの発言 i の本文（語をつなげたもの）
    func text(ofSegment i: Int) -> String { words[segments[i]].map(\.text).joined() }

    /// 語 w を含む文の最初の語（吹き出しの頭より前には戻らない）。文は、発言の頭か「。」「？」「！」の後から始まる
    func sentenceStart(of w: Int) -> Int { Self.sentenceStart(of: w, in: words, from: blocks[words[w].block].words.lowerBound) }

    static func sentenceStart(of w: Int, in words: [Word], from lower: Int) -> Int {
        var i = w
        while i > lower, words[i - 1].segment == words[i].segment,
              !(words[i - 1].text.trimmingCharacters(in: .whitespaces).last.map { "。．.？！?!".contains($0) } ?? false) {
            i -= 1
        }
        return i
    }

    /// 開始が t 以降の最初の語
    static func firstWord(in words: [Word], atOrAfter t: Double) -> Int? {
        var lo = 0, hi = words.count
        while lo < hi {
            let m = (lo + hi) / 2
            if words[m].start < t { lo = m + 1 } else { hi = m }
        }
        return lo < words.count ? lo : nil
    }

    /// 吹き出しの本文の中の、語ごとの範囲（UTF-16）
    func ranges(of block: Block) -> [NSRange] {
        var offset = 0
        return words[block.words].map { w in
            defer { offset += w.text.utf16.count }
            return NSRange(location: offset, length: w.text.utf16.count)
        }
    }

    /// 開始が t 以前の最後の単語（話し終えた語と今の語の境目）
    func lastStarted(_ t: Double) -> Int? {
        var lo = 0, hi = words.count - 1, ans: Int?
        while lo <= hi {
            let m = (lo + hi) / 2
            if words[m].start <= t { ans = m; lo = m + 1 } else { hi = m - 1 }
        }
        return ans
    }

    /// 再生位置 t で話している単語: 開始が t 以前の最後の単語（発話が途切れて 0.6 秒以上たったら無し）
    func wordAt(_ t: Double) -> Int? {
        guard let w = lastStarted(t), t - max(words[w].end, words[w].start) < 0.6 else { return nil }
        return w
    }

    /// 再生位置 t の発言（単語の合間でも発言の区間内ならその発言）
    func blockAt(_ t: Double) -> Int? {
        if let w = wordAt(t) { return words[w].block }
        return blocks.first { $0.start <= t && t <= $0.end }?.id
    }

    /// 時刻 t を含む発言（前後 tolerance 秒の余裕を見る。シークバーで短い発言にもポインタを合わせられるように）
    func block(near t: Double, tolerance: Double) -> Int? {
        blocks.first { $0.start - tolerance <= t && t <= $0.end + tolerance }?.id
    }

    /// 再生位置 t で話している話者（話者分離の区間が t を含む）
    func talking(at t: Double) -> Set<String> {
        Set(turns.lazy.filter { $0.start <= t && t < $0.end }.map(\.speaker))
    }

    /// 検索: 発言の本文をつなげて照合し、一致した箇所ごとに単語の番号を返す
    func search(_ query: String) -> [[Int]] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var hits: [[Int]] = []
        for b in blocks {
            var text = "", owner: [Int] = []
            for i in b.words {
                let w = words[i].text.lowercased()
                text += w
                owner += Array(repeating: i, count: w.count)
            }
            var from = text.startIndex
            while let r = text.range(of: q, range: from..<text.endIndex) {
                let a = text.distance(from: text.startIndex, to: r.lowerBound), n = q.count
                var ids: [Int] = []
                for i in owner[a..<a + n] where ids.last != i { ids.append(i) }
                hits.append(ids)
                from = r.upperBound
            }
        }
        return hits
    }
}

extension NSColor {
    /// ライト表示とダーク表示で切り替わる色（0xRRGGBB）
    convenience init(light: Int, dark: Int) {
        func color(_ hex: Int) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
        self.init(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? color(dark) : color(light) }
    }
}
