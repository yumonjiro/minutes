import Foundation
import Tidying

/// 文字起こしの表示の仕方: 原文・整形（つなぎ言葉と相槌を取り除いた表示）・見比べ（左に原文、右に整形）
enum TranscriptMode: String {
    case original, tidied, compare
}

/// 整形した文字起こしの表示用のデータ: 吹き出しごとに、整形した本文・語ごとの本文の中の範囲・元の本文の中で消した所。
/// 語の番号は原文と同じなので、再生に合わせた印・注釈・検索は、語の範囲を付け替えるだけでそのまま使える
struct TidiedTranscript {
    enum State {
        /// まだ整形していない発言がある（その発言は原文のまま）
        case pending
        case done
        /// 吹き出しの発言をすべて省いた
        case dropped
    }

    struct Block {
        var text: String
        /// 語ごとの、整形した本文の中の範囲（消した語は長さ 0）
        var words: [NSRange]
        /// 元の本文（語をつなげたもの）の中で消した範囲
        var removed: [NSRange]
        var state: State
        /// 省いた理由（dropped のとき。「省略（相槌）」）
        var note: String?
    }

    let blocks: [Block]
    /// 省いた発言の数と、発言の中で取り除いた所の数
    let droppedCount: Int
    let removedCount: Int

    init(model: TranscriptModel, outcomes: [Int: TidyOutcome]) {
        // 語ごとの、整形後の文字と、語の中で消した範囲（吹き出しは見出しの所で発言の途中から分かれることがあるので、語を単位にする）
        var kept = model.words.map(\.text), cuts = [[NSRange]](repeating: [], count: model.words.count)
        var droppedCount = 0, removedCount = 0
        for (i, range) in model.segments.enumerated() {
            guard let outcome = outcomes[i] else { continue }
            let length = model.words[range].reduce(0) { $0 + $1.text.utf16.count }
            let removed = outcome.dropped ? [0..<length] : outcome.removed.map { $0[0]..<$0[1] }
            if outcome.dropped { droppedCount += 1 } else { removedCount += removed.count }
            var local = 0
            for w in range {
                let n = model.words[w].text.utf16.count
                cuts[w] = removed.compactMap { r in
                    let lo = max(r.lowerBound, local), hi = min(r.upperBound, local + n)
                    return lo < hi ? NSRange(location: lo - local, length: hi - lo) : nil
                }
                var units = Array(model.words[w].text.utf16)
                for c in cuts[w].reversed() { units.removeSubrange(c.location..<NSMaxRange(c)) }
                kept[w] = String(decoding: units, as: UTF16.self)
                local += n
            }
        }
        blocks = model.blocks.map { block in
            var text = "", words: [NSRange] = [], removed: [NSRange] = [], origin = 0
            var pending = false, kinds: Set<TidyOutcome.Kind> = []
            for w in block.words {
                words.append(NSRange(location: text.utf16.count, length: kept[w].utf16.count))
                text += kept[w]
                removed += cuts[w].map { NSRange(location: origin + $0.location, length: $0.length) }
                origin += model.words[w].text.utf16.count
                if let outcome = outcomes[model.words[w].segment] { kinds.insert(outcome.kind) } else { pending = true }
            }
            let dropped = !pending && !block.words.isEmpty && kinds.allSatisfy { $0 != .clean && $0 != .trimmed }
            return Block(text: text, words: words, removed: removed, state: pending ? .pending : dropped ? .dropped : .done,
                         note: dropped ? "省略（\(Self.label(kinds))）" : nil)
        }
        self.droppedCount = droppedCount
        self.removedCount = removedCount
    }

    private static func label(_ kinds: Set<TidyOutcome.Kind>) -> String {
        guard kinds.count == 1, let kind = kinds.first else { return "相槌など" }
        return switch kind {
        case .backchannel: "相槌"
        case .laughter: "笑い声"
        case .filler: "つなぎ言葉だけ"
        case .noise: "誤認識とみられる文字"
        case .clean, .trimmed: "相槌など"
        }
    }
}
