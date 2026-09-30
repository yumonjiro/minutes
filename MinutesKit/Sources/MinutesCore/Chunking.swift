// 文字起こしの区切り。
// 区切りは最初を短く、だんだん長くする（最初の発言を早く画面に出すため）。
// 区切る位置は必ず無音区間（全話者の発話確率が 0.5 未満の状態が 0.4 秒以上続く所）の中央。
// 目安の長さの 0.5〜1.5 倍の範囲で目安に最も近い無音を選び、無ければ次の無音まで延ばす。

let scheduleSec: [Double] = [5, 10, 20, 40]
let maxChunkSec: Double = 60
let minSilenceSec = 0.4
let activeProb: Float = 0.5

/// 全話者の発話確率が 0.5 未満の状態が minSilenceSec 以上続く区間の中央（秒）
func silenceCenters(probs: [[Float]], frameSec: Double) -> [Double] {
    var centers: [Double] = []
    var quietStart: Int?
    for f in 0...probs.count {
        let quiet = f < probs.count && (probs[f].max() ?? 0) < activeProb
        if quiet, quietStart == nil { quietStart = f }
        if !quiet, let a = quietStart {
            if Double(f - a) * frameSec >= minSilenceSec { centers.append(Double(a + f) / 2 * frameSec) }
            quietStart = nil
        }
    }
    return centers
}

/// start から target 秒ほど先の区切り
func nextCut(start: Double, target: Double, silences: [Double], total: Double) -> Double {
    let want = start + target
    if want >= total { return total }
    let near = silences.filter { start + target * 0.5 <= $0 && $0 <= start + target * 1.5 }
    if let best = near.min(by: { abs($0 - want) < abs($1 - want) }) { return best }
    return silences.first { $0 > want } ?? total  // 無音以外では切らない
}

/// 区切り [(開始, 終了)] の一覧
func chunks(silences: [Double], total: Double) -> [(start: Double, end: Double)] {
    var result: [(start: Double, end: Double)] = []
    var start = 0.0
    while start < total - 0.05 {
        let n = result.count
        let end = nextCut(start: start, target: n < scheduleSec.count ? scheduleSec[n] : maxChunkSec, silences: silences, total: total)
        result.append((start: start, end: end))
        start = end
    }
    return result
}

/// 小数 2 桁に丸める（結果ファイルの秒）
func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
