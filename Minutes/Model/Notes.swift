import AppKit
import Foundation

/// 録音に重ねる注釈（notes.json）: ハイライト（色とコメント）・ブックマーク（発言）・見出し（発言の前。議題と小見出し）。
/// 文字起こしそのものは変えず、語の時刻で位置を結び付ける（文字起こしをやり直しても、同じ時刻の所に付く）
struct Notes: Codable, Equatable {
    var items: [Annotation] = []

    /// 見出しの時刻（ここで吹き出しを分ける）
    var splits: [Double] { items.filter { $0.kind == .heading }.map(\.from).sorted() }
}

struct Annotation: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case highlight, bookmark, heading
    }

    var id = UUID()
    var kind: Kind
    /// 範囲（秒）。ハイライトは最初の語の始まりから最後の語の終わりまで、ブックマークと見出しは発言の始まり
    var from: Double
    var to: Double
    /// ハイライトの色（HighlightColor の番号）
    var color = 0
    /// 見出しの段（1: 議題、2: 小見出し）
    var level = 1
    /// ハイライトのコメント・見出しの名前
    var text = ""
    var created = Date()
}

/// ハイライトの 5 色。意味の名前は設定で変えられる（アプリ全体で共通）
enum HighlightColor {
    static let count = 5
    static let defaultNames = ["重要", "決定", "課題", "TODO", "質問"]
    /// 色見本や印に使う色
    static let solid: [NSColor] = [.systemYellow, .systemGreen, .systemRed, .systemBlue, .systemPurple]

    /// 文字の後ろに敷く色（ライト・ダークとも文字が読める薄さ）
    static func fill(_ i: Int) -> NSColor {
        solid[min(max(i, 0), count - 1)].withAlphaComponent(i == 0 ? 0.38 : 0.26)
    }

    static func nameKey(_ i: Int) -> String { "highlight.name.\(i)" }

    static func name(_ i: Int) -> String {
        let i = min(max(i, 0), count - 1)
        let name = UserDefaults.standard.string(forKey: nameKey(i))?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? defaultNames[i] : name
    }
}

/// 注釈を、この文字起こしの語・発言の番号に結び付けたもの（描くとき・一覧に出すときに使う）
struct ResolvedNotes: Equatable {
    struct Highlight: Equatable, Identifiable {
        var id: UUID
        /// 語の範囲（全体の番号）
        var words: ClosedRange<Int>
        var color: Int
        var comment: String
    }

    struct Heading: Equatable, Identifiable {
        var id: UUID
        /// この見出しの後に続く発言
        var block: Int
        var level: Int
        var title: String
    }

    /// 始まりの順
    var highlights: [Highlight] = []
    /// ブックマークした発言（発言の番号 → 注釈）
    var bookmarks: [Int: UUID] = [:]
    /// 発言の順（同じ発言に 2 つあれば、議題が先）
    var headings: [Heading] = []

    /// 発言 b にかかるハイライト
    func highlights(in range: Range<Int>) -> [Highlight] {
        highlights.filter { $0.words.lowerBound < range.upperBound && $0.words.upperBound >= range.lowerBound }
    }

    /// 発言 b の前の見出し
    func headings(before b: Int) -> [Heading] { headings.filter { $0.block == b } }

    /// 発言 b が入っている見出し（b 以前で最後の見出し）
    func heading(containing b: Int) -> Heading? { headings.last { $0.block <= b } }
}

extension TranscriptModel {
    /// 注釈を語・発言の番号に結び付ける。語が見つからない注釈（文字起こしの外）は出さない
    func resolve(_ notes: Notes) -> ResolvedNotes {
        var r = ResolvedNotes()
        for a in notes.items {
            switch a.kind {
            case .highlight:
                guard let w0 = firstWord(atOrAfter: a.from - 0.01), let w1 = lastStarted(a.to - 0.001), w1 >= w0 else { continue }
                r.highlights.append(.init(id: a.id, words: w0...w1, color: a.color, comment: a.text))
            case .bookmark:
                if let b = block(startingNear: a.from) { r.bookmarks[b] = a.id }
            case .heading:
                if let b = block(startingNear: a.from) { r.headings.append(.init(id: a.id, block: b, level: a.level, title: a.text)) }
            }
        }
        r.highlights.sort { $0.words.lowerBound < $1.words.lowerBound }
        r.headings.sort { ($0.block, $0.level) < ($1.block, $1.level) }
        return r
    }

    /// 始まりが t 以降の最初の語
    func firstWord(atOrAfter t: Double) -> Int? { Self.firstWord(in: words, atOrAfter: t) }

    /// 時刻 t から始まる発言（なければ t を含む発言、それもなければ t の後の最初の発言）
    func block(startingNear t: Double) -> Int? {
        if let b = blocks.firstIndex(where: { abs($0.start - t) < 0.05 }) { return b }
        return firstWord(atOrAfter: t - 0.01).map { words[$0].block }
    }
}
