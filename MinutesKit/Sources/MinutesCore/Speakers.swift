// 話者の割り当てと、発言単位への区切り（規則は実際の録音で調整したもの）。
//   - 話者は Whisper の区間（おおむね文）ごとに、区間内の発話確率の合計が最大の話者。
//     Whisper の語の時刻は区間の端でずれやすく、語ごとに決めると端の 1〜2 語が隣の話者になるため
//   - 発言は「話者の交代」「文末」「長い無音」で区切る
//   - 誰も話していない所の区間は捨てる。無音に Whisper が「ご視聴ありがとうございました」などの幻の文を出し、
//     それを誰かの発言にしてしまうため。相槌や声の重なりは発話確率が 0.5 に届かないことがあるので、0.2 で判定する
//   - 笑い声などで Whisper が同じ文字を出し続けたとき（「wwww…」「フフフ…」）は、maxRepeat 文字で切る

import Diarization
import Transcription

let maxGapSec = 1.5
let sentenceEnd = Set("。？！?!")
let punctuationEnd = Set("。、？！?!,.")
let maxRepeat = 10  // 同じ文字がこれだけ続いたら、以降の同じ文字だけの語は捨てる

func speakerName(_ index: Int) -> String { "speaker_\(index)" }

/// 同じ 1 文字だけの語が続き、その文字が maxRepeat 文字に達したら、以降の同じ文字だけの語を捨てる（clamp_repeats）
func clampRepeats(_ words: [WhisperWord]) -> [WhisperWord] {
    var out: [WhisperWord] = [], char: Character?, run = 0
    for w in words {
        if run >= maxRepeat, let char, !w.text.isEmpty, w.text.allSatisfy({ $0 == char }) { continue }
        out.append(w)
        for c in w.text {
            run = c == char ? run + 1 : 1
            char = c
        }
    }
    return out
}

/// 話者の付いた語（seg は Whisper の区間の通し番号）
struct SpokenWord {
    var text: String
    var start: Double
    var end: Double
    var seg: Int
    var speaker: String
}

/// 話者分離の結果（frameSec ごとの話者別発話確率と話者区間）
struct SpeakerTimeline {
    let probs: [[Float]]
    let frameSec: Double
    let turns: [Transcript.Turn]
    private let speakers: Int

    init(_ diarization: DiarizationResult) {
        probs = diarization.probs
        frameSec = diarization.frameSec
        turns = diarization.turns.map { Transcript.Turn(start: $0.start, end: $0.end, speaker: speakerName($0.speaker)) }
        speakers = probs.first?.count ?? 0
    }

    /// 区間のフレーム（numpy の probs[f0:max(f0 + 1, ceil(end / frame_sec))]）
    private func frames(_ start: Double, _ end: Double) -> ArraySlice<[Float]> {
        let f0 = Int(start / frameSec), f1 = max(f0 + 1, Int((end / frameSec).rounded(.up)))
        return probs[min(f0, probs.count)..<min(f1, probs.count)]
    }

    /// 区間の中で誰かが話しているか（発話確率が 0.2 以上のフレームがあるか。相槌や声の重なりは 0.5 に届かないことがあり、
    /// 無音はほぼ 0 なので、話者区間を作る基準の 0.5 より低くする）
    func hasSpeech(_ start: Double, _ end: Double) -> Bool {
        frames(start, end).contains { $0.contains { $0 >= 0.2 } }
    }

    /// 区間内で発話確率の合計が最大の話者（segment_speaker。同じなら番号の小さい方）
    func dominantSpeaker(_ start: Double, _ end: Double) -> String {
        var sums = [Float](repeating: 0, count: speakers)
        for frame in frames(start, end) { for i in 0..<speakers { sums[i] += frame[i] } }
        return speakerName(sums.indices.max { sums[$0] < sums[$1] } ?? 0)
    }

    /// Whisper の区間ごとに話者を決め、その区間の語に付ける（assign_by_segment）。
    /// offset は区切りの開始秒、firstSeg は区間の通し番号の始まり
    func assign(_ segments: [WhisperSegment], offset: Double, firstSeg: Int) -> [SpokenWord] {
        segments.enumerated().flatMap { k, s -> [SpokenWord] in
            guard hasSpeech(s.start + offset, s.end + offset) else { return [] }  // 誰も話していない所の幻の文
            let speaker = dominantSpeaker(s.start + offset, s.end + offset)
            return clampRepeats(s.words).map {
                SpokenWord(text: $0.text, start: round2($0.start + offset), end: round2($0.end + offset), seg: firstSeg + k, speaker: speaker)
            }
        }
    }

    /// 話者の付いた語の列を、話者の交代・文末・長い無音で区切った発言にする（build_segments）
    func utterances(_ words: [SpokenWord], firstID: Int) -> [Transcript.Segment] {
        var groups: [[SpokenWord]] = []
        for w in words {
            if let last = groups.last?.last, w.speaker == last.speaker, !last.text.hasSuffix(in: sentenceEnd),
               w.start - last.end < maxGapSec {
                groups[groups.count - 1].append(w)
            } else {
                groups.append([w])
            }
        }
        return groups.enumerated().map { n, members -> Transcript.Segment in
            // Whisper の区間の切れ目に句読点が無ければ、元の出力どおり空白で区切る
            let texts = members.indices.map { i -> String in
                let gap = i > 0 && members[i].seg != members[i - 1].seg && !members[i - 1].text.hasSuffix(in: punctuationEnd)
                return (gap ? " " : "") + members[i].text
            }
            let start = members[0].start, end = members[members.count - 1].end
            var overlap: [(speaker: String, sec: Double)] = []  // 出てきた順（最大が並んだら先の話者）
            for turn in turns {
                let o = min(end, turn.end) - max(start, turn.start)
                guard o > 0 else { continue }
                if let k = overlap.firstIndex(where: { $0.speaker == turn.speaker }) { overlap[k].sec += o } else { overlap.append((speaker: turn.speaker, sec: o)) }
            }
            let window = frames(start, end)
            var prob: [String: Double] = [:]
            for i in 0..<speakers where window.contains(where: { $0[i] >= 0.1 }) {
                prob[speakerName(i)] = window.reduce(0.0) { $0 + Double($1[i]) } / Double(window.count)
            }
            return Transcript.Segment(
                id: firstID + n, start: start, end: end, text: texts.joined(), speaker: members[0].speaker,
                overlapBySpeaker: Dictionary(uniqueKeysWithValues: overlap.map { ($0.speaker, $0.sec) }),
                probBySpeaker: prob,
                speakerByOverlap: overlap.max { $0.sec < $1.sec }?.speaker,
                words: zip(texts, members).map { Transcript.Word(w: $0, s: $1.start, e: $1.end) })
        }
    }
}

extension String {
    fileprivate func hasSuffix(in characters: Set<Character>) -> Bool { last.map(characters.contains) ?? false }
}
