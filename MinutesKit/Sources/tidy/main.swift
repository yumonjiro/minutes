// tidy: 発言の整形（Tidying）を試す。transcript.json の発言を 1 つずつ整形し、消した所・モデルの出力・時間を表示する
//
//   tidy <transcript.json | 発言を 1 行に 1 つ書いた .txt> [--model <Gemma4-E2B-IT-Text-int4 のフォルダ>] [--limit <発言数>] [--verbose]
//
// 消した所は ⟦ ⟧ で囲んで表示する。--verbose ならモデルの出力（確かめる前）も出す
import Foundation
import MinutesCore
import ModelStore
import Tidying

var positional: [String] = []
var options: [String: String] = [:]
var flags: Set<String> = []
do {
    var args = CommandLine.arguments.dropFirst()
    while let arg = args.popFirst() {
        if ["--model", "--limit"].contains(arg), let value = args.popFirst() {
            options[arg] = value
        } else if arg.hasPrefix("--") {
            flags.insert(arg)
        } else {
            positional.append(arg)
        }
    }
}
guard let path = positional.first else {
    FileHandle.standardError.write(Data("使い方: tidy <transcript.json> [--model <フォルダ>] [--limit <発言数>] [--verbose]\n".utf8))
    exit(1)
}

/// 整形する発言（.txt なら行ごと。前の発言は無し扱い）
struct Utterance {
    var start = 0.0
    var speaker = ""
    var text: String
}
let utterances: [Utterance]
if path.hasSuffix(".txt") {
    utterances = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init)
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }.map { Utterance(text: $0) }
} else {
    utterances = try Transcript(jsonData: Data(contentsOf: URL(filePath: path))).segments
        .map { Utterance(start: $0.start, speaker: $0.speaker, text: $0.words.map(\.w).joined()) }
}
let segments = utterances.prefix(options["--limit"].flatMap(Int.init) ?? .max)
let model: URL
if let folder = options["--model"] { model = URL(filePath: folder) } else { model = try await ModelStore().pathsDownloadingIfNeeded().tidier }
let tidier = Tidier(modelFolder: model)
let clock = ContinuousClock()
let loadTime = try await clock.measure { try await tidier.load() }
print(String(format: "モデルの読み込み: %.1f 秒", loadTime.seconds))

/// 消した所を ⟦ ⟧ で囲む
func marked(_ text: String, _ outcome: TidyOutcome) -> String {
    let units = Array(text.utf16)
    var out: [UInt16] = [], i = 0
    for r in outcome.removed {
        out += units[i..<r[0]] + "⟦".utf16 + units[r[0]..<r[1]] + "⟧".utf16
        i = r[1]
    }
    return String(decoding: out + units[i...], as: UTF16.self)
}

var kinds: [TidyOutcome.Kind: Int] = [:]
var before = 0, after = 0
var slowest: (seconds: Double, text: String) = (0, "")
let started = clock.now
for (i, segment) in segments.enumerated() {
    let text = segment.text
    let previous = i > 0 && !segment.speaker.isEmpty && utterances[i - 1].speaker != segment.speaker ? utterances[i - 1].text : nil
    var outcome = TidyOutcome(kind: .clean)
    let elapsed = try await clock.measure { outcome = try await tidier.tidy(text, previous: previous) }.seconds
    kinds[outcome.kind, default: 0] += 1
    before += text.count
    after += outcome.apply(to: text).count
    if elapsed > slowest.seconds { slowest = (elapsed, text) }
    let label = outcome.dropped ? "省く(\(outcome.kind.rawValue))" : outcome.kind.rawValue
    print(String(format: "%3d %6.1fs %-18@ %.2fs  ", i, segment.start, label as NSString, elapsed) + marked(text, outcome))
    if flags.contains("--verbose") {
        for e in await tidier.exchanges { print("      モデル: \(e.output.replacingOccurrences(of: "\n", with: "⏎"))") }
    }
}
let total = (clock.now - started).seconds
let stats = await tidier.stats
print("")
print("発言 \(segments.count)・" + kinds.sorted { $0.value > $1.value }.map { "\($0.key.rawValue) \($0.value)" }.joined(separator: "・"))
print(String(format: "文字数 %d → %d（%.0f%%）", before, after, Double(after) / Double(max(1, before)) * 100))
print(String(format: "モデル %d 回・%.1f 秒（1 回 %.2f 秒）・書き換えで使わなかった出力 %d・確かめて戻した所 %d", stats.modelCalls, stats.modelSeconds,
             stats.modelSeconds / Double(max(1, stats.modelCalls)), stats.rewrites, stats.restored))
print(String(format: "合計 %.1f 秒（1 発言 %.2f 秒）・最も遅い発言 %.1f 秒: %@", total, total / Double(max(1, segments.count)), slowest.seconds,
             String(slowest.text.prefix(40)) as NSString))

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
