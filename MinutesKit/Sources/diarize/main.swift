// 話者分離の CLI（Diarization の動作確認用）
//   diarize <音声ファイル> [--out result.json] [--units cpu|gpu|all]
// モデルは既定でアプリと同じもの（ModelStore。無ければ Hugging Face から取得する）を使う
import CoreML
import Diarization
import Foundation
import ModelStore

var options: [String: String] = [:], files: [String] = []
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    if argument.hasPrefix("--") { options[argument] = arguments.next() } else { files.append(argument) }
}
guard let audio = files.first else {
    print("usage: diarize <audio file> [--out result.json] [--units cpu|gpu|all]")
    exit(1)
}
let models = try await ModelStore().pathsDownloadingIfNeeded()
let units: [String: MLComputeUnits] = ["cpu": .cpuOnly, "gpu": .cpuAndGPU, "all": .all]

func seconds(since start: Date) -> String { String(format: "%.2f s", Date().timeIntervalSince(start)) }

var start = Date()
let samples = try decodeAudio16kMono(url: URL(fileURLWithPath: audio))
print("decode: \(seconds(since: start)) (\(samples.count) samples, \(String(format: "%.1f", Double(samples.count) / 16000)) s)")

start = Date()
let diarizer = try NemotronDiarizer(
    modelURL: models.diarizer,
    silenceEmbeddingURL: models.silenceEmbedding,
    computeUnits: units[options["--units"] ?? "gpu"] ?? .cpuAndGPU)
print("load: \(seconds(since: start))")

start = Date()
let result = try diarizer.diarize(samples)
let probs = result.probs.flatMap { $0 }
func activeSpeakers(_ p: [Float]) -> [Int] { (0..<8).filter { s in stride(from: s, to: p.count, by: 8).contains { p[$0] > 0.5 } } }
print("diarize: \(seconds(since: start)) (\(result.probs.count) frames, \(result.turns.count) turns, speakers \(activeSpeakers(probs)))")

if let out = options["--out"] {
    try JSONEncoder().encode(result).write(to: URL(fileURLWithPath: out))
}

