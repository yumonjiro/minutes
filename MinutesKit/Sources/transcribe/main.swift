// 文字起こしの CLI（MinutesCore の動作確認用。アプリと同じ結果ファイルを区切りごとに書き換える）
//   transcribe <音声ファイル> --out result.json [--cache-limit MB] [--memory-limit MB] [--memlog memory.tsv]
// モデルは既定でアプリと同じもの（ModelStore。無ければ Hugging Face から取得する）を使う
// メモリの確認用: 0.25 秒ごとにプロセスのメモリ（phys_footprint）と MLX の active・cache を測り、段階・区切りごとと全体の最大を出す。
//   --cache-limit/--memory-limit は MLX の Memory.cacheLimit/memoryLimit を変える（cacheLimit は文字起こしを始めるときに変える）。
//   --memlog は測った値を TSV に書く
import Foundation
import MinutesCore
import ModelStore
import MLX

setvbuf(stdout, nil, _IOLBF, 0)  // 進み具合をパイプ越しにもすぐ出す
var options: [String: String] = [:], files: [String] = []
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    if argument.hasPrefix("--") { options[argument] = arguments.next() } else { files.append(argument) }
}
guard let audio = files.first.map(URL.init(fileURLWithPath:)), let out = options["--out"].map(URL.init(fileURLWithPath:)) else {
    print("usage: transcribe <audio file> --out result.json [--cache-limit MB] [--memory-limit MB] [--memlog memory.tsv]")
    exit(1)
}
let models = try await ModelStore().pathsDownloadingIfNeeded()

let processor = MeetingProcessor(
    models: .init(diarizer: models.diarizer, silenceEmbedding: models.silenceEmbedding,
                  whisper: models.whisper))

if let mb = options["--memory-limit"].flatMap(Int.init) { Memory.memoryLimit = mb * 1_048_576 }
print("MLX memoryLimit \(megabytes(Memory.memoryLimit)) MB, cacheLimit \(megabytes(Memory.cacheLimit)) MB,"
    + " recommendedMaxWorkingSetSize \(megabytes(GPU.maxRecommendedWorkingSetBytes() ?? 0)) MB")

let start = Date()
let sampler = MemorySampler(log: options["--memlog"], start: start)
func elapsed() -> String { String(format: "%6.1f s", Date().timeIntervalSince(start)) }
var stageStart = start
var mlxPeak = 0
/// 前の行からのメモリの最大（MLX の peak は測り直す）
@MainActor func memoryLine() -> String {
    let p = sampler.take(), peak = Memory.peakMemory
    Memory.peakMemory = 0
    mlxPeak = max(mlxPeak, peak)
    return "           mem: footprint max \(megabytes(p.footprint)) MB, MLX active max \(megabytes(p.active)) MB"
        + " (peak \(megabytes(peak)) MB), cache max \(megabytes(p.cache)) MB"
}
for try await event in await processor.process(audio: audio) {
    switch event {
    case .stage(let stage):
        print(memoryLine())
        print("\(elapsed())  \(stage)  (previous stage \(String(format: "%.1f", Date().timeIntervalSince(stageStart))) s)")
        stageStart = Date()
        if stage == .transcribing {  // cacheLimit は Whisper の読み込みで決まるので、ここで変える
            if let mb = options["--cache-limit"].flatMap(Int.init) { Memory.cacheLimit = mb * 1_048_576 }
            print("MLX cacheLimit \(megabytes(Memory.cacheLimit)) MB")
        }
    case .diarizing:
        break
    case .partial(let transcript), .finished(let transcript):
        try transcript.jsonData().write(to: out, options: .atomic)  // アプリが書きかけを読まないよう置き換える
        let p = transcript.progress
        print("\(elapsed())  @@partial \(p.doneSec) \(p.totalSec)  chunks \(p.chunks.count), utterances \(transcript.segments.count)")
        print(memoryLine())
        if p.final {
            print("done: \(transcript.segments.count) utterances, timings \(transcript.timingsSec)")
        }
    }
}
let overall = sampler.overall
print("total \(elapsed()), peak memory \(megabytes(footprint().peak)) MB (sampled max \(megabytes(overall.footprint)) MB),"
    + " MLX active max \(megabytes(overall.active)) MB (peak \(megabytes(mlxPeak)) MB), MLX cache max \(megabytes(overall.cache)) MB")

/// プロセスの物理メモリ使用量（Activity Monitor の「メモリ」と同じ phys_footprint）の今と最大（バイト）
func footprint() -> (current: Int, peak: Int) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? (Int(info.phys_footprint), Int(info.ledger_phys_footprint_peak)) : (-1, -1)
}

func megabytes(_ bytes: Int) -> Int { bytes / 1_048_576 }

/// 0.25 秒ごとにメモリを測り、最大を覚える（take で前回からの最大を返して測り直す）
final class MemorySampler: @unchecked Sendable {
    struct Peaks {
        var footprint = 0, active = 0, cache = 0
        func max(_ o: Peaks) -> Peaks {
            Peaks(footprint: Swift.max(footprint, o.footprint), active: Swift.max(active, o.active), cache: Swift.max(cache, o.cache))
        }
    }

    private let lock = NSLock()
    private var recent = Peaks(), all = Peaks()
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "memory-sampler"))
    private let log: FileHandle?

    init(log path: String?, start: Date) {
        log = path.flatMap { FileManager.default.createFile(atPath: $0, contents: Data("sec\tfootprint_mb\tactive_mb\tcache_mb\n".utf8)) ? FileHandle(forWritingAtPath: $0) : nil }
        log?.seekToEndOfFile()
        timer.setEventHandler { [unowned self] in
            let now = Peaks(footprint: footprint().current, active: Memory.activeMemory, cache: Memory.cacheMemory)
            lock.withLock {
                recent = recent.max(now)
                all = all.max(now)
            }
            log?.write(Data(String(format: "%.2f\t%d\t%d\t%d\n", Date().timeIntervalSince(start),
                                   megabytes(now.footprint), megabytes(now.active), megabytes(now.cache)).utf8))
        }
        timer.schedule(deadline: .now(), repeating: 0.25)
        timer.activate()
    }

    func take() -> Peaks { lock.withLock { defer { recent = Peaks() }; return recent } }
    var overall: Peaks { lock.withLock { all } }
}
