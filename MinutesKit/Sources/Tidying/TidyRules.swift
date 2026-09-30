import Foundation

/// 整形の決まり: モデルを使わずに決める所と、モデルが消した所の確かめ。文字の位置はすべて UTF-16
enum TidyRules {
    private static func units(_ words: [String]) -> [[UInt16]] { words.map { Array($0.utf16) } }

    /// 区切り（読点・空白）と文の終わり
    static let pauses = Set("、，,　 ".utf16)
    static let enders = Set("。．.？！?!\n".utf16)
    static let others = Set("・…「」『』（）()〜~".utf16)
    static func isPunctuation(_ u: UInt16) -> Bool { pauses.contains(u) || enders.contains(u) || others.contains(u) }

    /// 必ずつなぎ言葉の語（どこにあっても決まりで消す。長いものから照らし合わせる）
    static let sure = units(["えーっと", "えーと", "えっと", "ええと", "えーー", "えー", "あのー", "そのー", "うーん", "うーむ", "んー", "あー",
                             "まあ", "まぁ", "なんていうか", "何て言うか", "なんというか", "何というか"])
    /// つなぎ言葉にも中身にもなる語（「あの人」「その資料」「なんか食べる」）。前後が区切りなら決まりで消し、
    /// そうでなければモデルが消したときに、後が区切りなら認める
    static let ambiguous = units(["あの", "その", "なんか", "こう", "ほら", "えと"])
    /// 1 文字のつなぎ言葉（前後が区切りのときだけ認める）
    static let single = Set("あえまんでう".utf16)
    /// つなぎ言葉でできていても中身の語
    static let protected = units(["まあまあ", "まぁまぁ", "まあね", "まぁね"])
    /// 区切りに挟まれていても切れ端とみなさない 1 文字（文頭の「が、」「と、」はつなぎの言葉）
    static let notFragments = Set("がと".utf16)
    /// 相槌（「はい」「うん」だけの発言は省く）
    static let backchannels = units(["はいはい", "はーい", "はい", "うんうん", "うん", "ええ", "そうそう", "そうですよね", "そうですね", "そうだね", "そうね",
                                     "そうなんですね", "そうなんだ", "そうか", "そっか", "そう", "なるほどね", "なるほど", "へえ", "へぇ", "へー", "ほう", "ほー",
                                     "ああ", "おお", "おー", "ふーん", "ふむ", "確かに", "たしかに", "ね", "ねー"])
    /// 笑い声の文字
    static let laughs = Set("はハふフへヘほホwｗ笑".utf16)
    /// 無音や雑音に付きやすい Whisper の誤り
    static let hallucinations = Set(["ご視聴ありがとうございました", "ご視聴ありがとうございます", "チャンネル登録よろしくお願いします", "チャンネル登録お願いします"])

    /// 発言ごと省くか
    static func dropKind(_ text: String) -> TidyOutcome.Kind? {
        let body = text.utf16.filter { !isPunctuation($0) }
        if body.isEmpty { return .filler }
        let s = String(decoding: body, as: UTF16.self)
        if hallucinations.contains(s) { return .noise }
        let laughing = body.filter(laughs.contains).count
        if (body.count >= 2 && laughing * 5 >= body.count * 4) || ["笑", "w", "ｗ"].contains(s) { return .laughter }
        // 「まあまあ」（中身の語）を含むなら省かない
        guard body.count <= 30, !touchesProtected(body, body.indices) else { return nil }
        // 「ええ」は「え」2 つでなく相槌（問いへの答えなら残す）とみなすため、相槌だけかを先に見る
        let fillers = sure + ambiguous + single.map { [$0] }
        if consists(of: backchannels, body) { return .backchannel }
        if consists(of: fillers, body) { return .filler }
        if consists(of: backchannels + fillers, body) { return .backchannel }
        return nil
    }

    /// 問いかけで終わる発言か
    static func isQuestion(_ text: String) -> Bool {
        guard let last = text.utf16.last(where: { !pauses.contains($0) }) else { return false }
        return Set("？?".utf16).contains(last)
    }

    /// 発言ごと省くか（問いへの「はい」は答えなので省かない）
    static func drop(_ text: String, previous: String?) -> TidyOutcome.Kind? {
        guard let kind = dropKind(text), kind != .backchannel || !(previous.map(isQuestion) ?? false) else { return nil }
        return kind
    }

    /// 発言の下ごしらえ: 文ごとに、決まりで消す所と、モデルに渡す文（決まりで消した後）
    struct Plan {
        struct Sentence {
            var range: Range<Int>
            var sure: [Bool]
            /// モデルに渡す文と、その各文字の文の中の位置
            var reduced: [UInt16]
            var kept: [Int]
            var needsModel: Bool
        }

        var units: [UInt16]
        var sentences: [Sentence]
    }

    static func plan(_ text: String) -> Plan {
        let units = Array(text.utf16)
        return Plan(units: units, sentences: sentences(units).map { range in
            let sentence = Array(units[range]), sure = sureDeletions(sentence)
            var shown = sure
            cleanPunctuation(sentence, &shown)
            let kept = sentence.indices.filter { !shown[$0] }, reduced = kept.map { sentence[$0] }
            return Plan.Sentence(range: range, sure: sure, reduced: reduced, kept: kept, needsModel: needsModel(reduced))
        })
    }

    /// 文ごとの消す案（文の中の位置）を確かめてまとめ、結果にする。restored: 確かめて元に戻した所の数
    static func finish(_ plan: Plan, proposals: [[Bool]]) -> (outcome: TidyOutcome, restored: Int) {
        let units = plan.units
        var deleted = [Bool](repeating: false, count: units.count), restored = 0
        for (sentence, proposal) in zip(plan.sentences, proposals) {
            let (verified, n) = verify(Array(units[sentence.range]), proposal: proposal, fallback: sentence.sure)
            restored += n
            for (i, d) in verified.enumerated() where d { deleted[sentence.range.lowerBound + i] = true }
        }
        cleanPunctuation(units, &deleted)
        if units.indices.allSatisfy({ deleted[$0] || isPunctuation(units[$0]) }) { return (TidyOutcome(kind: .filler), restored) }
        let removed = runs(deleted, in: units.indices).map { [$0.lowerBound, $0.upperBound] }
        return (TidyOutcome(kind: removed.isEmpty ? .clean : .trimmed, removed: removed), restored)
    }

    /// s が words の並びだけでできているか
    static func consists(of words: [[UInt16]], _ s: [UInt16]) -> Bool {
        var reachable = [Bool](repeating: false, count: s.count + 1)
        reachable[0] = true
        for i in s.indices where reachable[i] {
            for w in words where s[i...].starts(with: w) { reachable[i + w.count] = true }
        }
        return reachable[s.count]
    }

    /// 文の範囲。「。」「？」「！」と改行で区切り、120 文字を超える文は 60 文字を過ぎた読点・空白でも区切る
    static func sentences(_ units: [UInt16]) -> [Range<Int>] {
        var ranges: [Range<Int>] = [], start = 0
        for (i, u) in units.enumerated() where enders.contains(u) || (pauses.contains(u) && i - start >= 60 && units.count - start > 120) {
            ranges.append(start..<i + 1)
            start = i + 1
        }
        if start < units.count { ranges.append(start..<units.count) }
        return ranges
    }

    /// 必ずつなぎ言葉の語の位置（決まりで消す）
    static func sureDeletions(_ s: [UInt16]) -> [Bool] {
        var deleted = [Bool](repeating: false, count: s.count), i = 0
        func pause(at k: Int) -> Bool { k == s.count || isPunctuation(s[k]) }
        while i < s.count {
            let bounded = i == 0 || isPunctuation(s[i - 1])
            var n = 0
            if let w = sure.first(where: { s[i...].starts(with: $0) }), !quoted(s, i + w.count) {
                n = w.count
            } else if bounded, let w = ambiguous.first(where: { s[i...].starts(with: $0) && pause(at: i + $0.count) }) {
                // 区切りに挟まれた「その」「あの」「なんか」はつなぎ言葉（「その資料」「なんか食べる」は後が区切りでない）
                n = w.count
            } else if bounded, single.contains(s[i]), pause(at: i + 1) {
                n = 1
            } else if bounded, let r = pausedRepeat(s, i) {
                n = r
            } else if bounded, let r = laughter(s, i), pause(at: i + r) {
                n = r
            }
            if n > 0, !touchesProtected(s, i..<i + n) {
                for k in i..<i + n { deleted[k] = true }
                i += n
            } else {
                i += 1
            }
        }
        return deleted
    }

    /// i から始まる語が、区切りを挟んですぐに繰り返される長さ（「資料を、資料を」の 3）。
    /// 漢字 1 文字は除く（「今、今日は」の「今」は中身）
    static func pausedRepeat(_ s: [UInt16], _ i: Int) -> Int? {
        for n in 1...12 where i + n < s.count {
            if isPunctuation(s[i + n - 1]) { return nil }
            guard isPunctuation(s[i + n]) else { continue }
            var j = i + n
            while j < s.count, isPunctuation(s[j]) { j += 1 }
            if j + n <= s.count, s[j..<j + n].elementsEqual(s[i..<i + n]), n >= 2 || isKana(s[i]) { return n }
        }
        return nil
    }

    /// i から始まる笑い声の長さ（「あははは」「wwww」: 笑いの文字が 3 つ以上。頭の「あ」も含める）
    static func laughter(_ s: [UInt16], _ i: Int) -> Int? {
        var j = i
        if j < s.count, Set("あア".utf16).contains(s[j]) { j += 1 }
        let start = j
        while j < s.count, laughs.contains(s[j]) { j += 1 }
        return j - start >= 3 ? j - i : nil
    }

    /// k から引用の「って」が続くか（「うーんって思った」の「うーん」は中身）
    static func quoted(_ s: [UInt16], _ k: Int) -> Bool { s[k...].starts(with: "って".utf16) }

    /// モデルに見分けてもらう所（つなぎ言葉か中身か見分けの要る語・区切りに挟まれたかな 1 文字・すぐの繰り返し）がある文か
    static func needsModel(_ s: [UInt16]) -> Bool {
        for i in s.indices where !isPunctuation(s[i]) {
            let pauseBefore = i == 0 || isPunctuation(s[i - 1])
            if ambiguous.contains(where: { s[i...].starts(with: $0) && (i + $0.count == s.count || isPunctuation(s[i + $0.count])) }) { return true }
            if pauseBefore, i + 1 == s.count || isPunctuation(s[i + 1]), isKana(s[i]), !notFragments.contains(s[i]) { return true }
            for n in 1...8 where i + n <= s.count {
                if isPunctuation(s[i + n - 1]) { break }
                var j = i + n
                while j < s.count, isPunctuation(s[j]) { j += 1 }
                if n >= 3 || j > i + n, j + n <= s.count, s[j..<j + n].elementsEqual(s[i..<i + n]) { return true }
            }
        }
        return false
    }

    /// モデルの出力から、消した所の案。句読点は比べない（足したり変えたりしても見逃す）。
    /// 同じ文字が続くときは前の方を消したとみなす（「その、その資料」なら前の「その」）。unmatched: 元に無い出力の文字の数（書き換え）
    static func modelDeletions(_ s: [UInt16], _ output: String) -> (deleted: [Bool], unmatched: Int) {
        let a = s.indices.filter { !isPunctuation(s[$0]) }
        let b = output.utf16.filter { !isPunctuation($0) }
        let n = a.count, m = b.count, width = m + 1
        // lcs[i * width + j]: a[i...] と b[j...] の最長共通部分列の長さ
        var lcs = [Int](repeating: 0, count: (n + 1) * width)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i * width + j] = s[a[i]] == b[j] ? lcs[(i + 1) * width + j + 1] + 1 : max(lcs[(i + 1) * width + j], lcs[i * width + j + 1])
            }
        }
        var deleted = [Bool](repeating: false, count: s.count), i = 0, j = 0, unmatched = 0
        while i < n {
            if lcs[(i + 1) * width + j] == lcs[i * width + j] {
                deleted[a[i]] = true
                i += 1
            } else if j < m, s[a[i]] == b[j] {
                i += 1
                j += 1
            } else {
                unmatched += 1
                j += 1
            }
        }
        return (deleted, unmatched + m - j)
    }

    /// 消す案を 1 か所ずつ確かめる。認められない所は fallback（決まりで消す所）だけ消す。restored: 元に戻した所の数
    static func verify(_ s: [UInt16], proposal: [Bool], fallback: [Bool]) -> (deleted: [Bool], restored: Int) {
        var d = proposal
        for i in s.indices where isPunctuation(s[i]) { d[i] = false }
        var restored = 0
        // 後ろから確かめる（すぐ後に残る言葉を、繰り返しかどうかの判断に使う）
        for chunk in runs(d, in: s.indices).reversed() where !acceptable(s, chunk, d) {
            restored += 1
            for k in chunk { d[k] = fallback[k] }
            for sub in runs(d, in: chunk).reversed() where !acceptable(s, sub, d) {
                for k in sub { d[k] = false }
            }
        }
        return (d, restored)
    }

    /// 消してよい所か: つなぎ言葉・すぐ後に続く言葉の繰り返し（どもり）だけでできている、または区切りに挟まれたかな 1 文字（言いかけの切れ端）
    static func acceptable(_ s: [UInt16], _ chunk: Range<Int>, _ d: [Bool]) -> Bool {
        if touchesProtected(s, chunk) { return false }
        let t = Array(s[chunk])
        let pauseBefore = chunk.lowerBound == 0 || isPunctuation(s[chunk.lowerBound - 1])
        let pauseAfter = chunk.upperBound == s.count || isPunctuation(s[chunk.upperBound])
        if t.count == 1, pauseBefore, pauseAfter, isKana(t[0]), !notFragments.contains(t[0]) { return true }
        if pauseBefore, pauseAfter, laughter(t, 0) == t.count { return true }
        // すぐ後に残る言葉（句読点・消す所を除く）
        var next: [UInt16] = [], k = chunk.upperBound
        while k < s.count, next.count < 24 {
            if !d[k], !isPunctuation(s[k]) { next.append(s[k]) }
            k += 1
        }
        var ok = [Bool](repeating: false, count: t.count + 1)
        ok[0] = true
        for i in t.indices where ok[i] {
            for w in sure where t[i...].starts(with: w) && (i + w.count < t.count || !quoted(s, chunk.upperBound)) { ok[i + w.count] = true }
            // 語の終わりが消す所の終わりなら、その後が区切りのときだけ（「あの人」の「あの」は消さない）
            for w in ambiguous where t[i...].starts(with: w) && (i + w.count < t.count || pauseAfter) { ok[i + w.count] = true }
            if single.contains(t[i]), i > 0 || pauseBefore, i + 1 < t.count || pauseAfter { ok[i + 1] = true }
            // 繰り返し: すぐ後に残る言葉の頭と同じ。2 文字以下は区切りを挟むときだけ（「どんどん」を守る）
            var n = 1
            while i + n <= t.count, n <= next.count, t[i + n - 1] == next[n - 1] {
                if n >= 3 || pauseAfter { ok[i + n] = true }
                n += 1
            }
        }
        return ok[t.count]
    }

    /// 消す所の後始末: 消した語の直後の読点・空白も消し、消したせいで先頭・文末・句読点の隣に残った読点を消す
    static func cleanPunctuation(_ s: [UInt16], _ d: inout [Bool]) {
        for i in s.indices where d[i] && !isPunctuation(s[i]) && (i + 1 == s.count || !d[i + 1]) {
            var j = i + 1
            while j < s.count, pauses.contains(s[j]) {
                d[j] = true
                j += 1
            }
        }
        var last: Int?, gap = false
        for i in s.indices {
            if d[i] {
                gap = true
                continue
            }
            if gap, pauses.contains(s[i]), last.map({ isPunctuation(s[$0]) }) ?? true {
                d[i] = true
                continue
            }
            if gap, enders.contains(s[i]), let l = last, pauses.contains(s[l]) { d[l] = true }
            last = i
            gap = false
        }
        if gap, let l = last, pauses.contains(s[l]) { d[l] = true }
    }

    /// 消す所の続き（範囲の中で d が true の連なり）
    static func runs(_ d: [Bool], in range: Range<Int>) -> [Range<Int>] {
        var result: [Range<Int>] = [], i = range.lowerBound
        while i < range.upperBound {
            guard d[i] else {
                i += 1
                continue
            }
            let start = i
            while i < range.upperBound, d[i] { i += 1 }
            result.append(start..<i)
        }
        return result
    }

    static func touchesProtected(_ s: [UInt16], _ r: Range<Int>) -> Bool {
        protected.contains { p in
            s.indices.contains { i in i < r.upperBound && r.lowerBound < i + p.count && s[i...].starts(with: p) }
        }
    }

    static func isKana(_ u: UInt16) -> Bool { (0x3041...0x3096).contains(u) || (0x30A1...0x30FA).contains(u) }
}
