// Whisper のトークナイザー（openai/whisper-large-v3 の tokenizer.json を swift-transformers で読む）。
// id は mlx_whisper（tiktoken）と同じ。文字列への戻し方は tiktoken の decode（UTF-8 として読めないバイトは U+FFFD）に合わせる

import Foundation
import Tokenizers

struct WhisperTextTokenizer {
    let eot: Int, sot: Int, sotPrev: Int, sotLM: Int, transcribe: Int, translate: Int
    let noSpeech: Int, noTimestamps: Int, timestampBegin: Int
    /// <|startoftranscript|> <|ja|> <|transcribe|>
    let sotSequence: [Int]
    private let upstream: any Tokenizer
    private let bytes: [[UInt8]]  // id ごとのバイト列（特殊トークンはその表記）

    /// folder: tokenizer.json と tokenizer_config.json。vocabularySize はモデルの n_vocab
    init(folder: URL, language: String, vocabularySize: Int) async throws {
        let upstream = try await AutoTokenizer.from(modelFolder: folder)
        self.upstream = upstream
        func id(_ token: String) throws -> Int {
            guard let id = upstream.convertTokenToId(token) else { throw WhisperTextTokenizerError.missingToken(token) }
            return id
        }
        eot = try id("<|endoftext|>")
        sot = try id("<|startoftranscript|>")
        sotPrev = try id("<|startofprev|>")
        sotLM = try id("<|startoflm|>")
        transcribe = try id("<|transcribe|>")
        translate = try id("<|translate|>")
        noSpeech = try id("<|nospeech|>")
        noTimestamps = try id("<|notimestamps|>")
        timestampBegin = try id("<|0.00|>")
        sotSequence = [sot, try id("<|\(language)|>"), transcribe]
        // バイト単位の BPE の表記（GPT-2 の bytes_to_unicode: 表示できるバイトはそのまま、それ以外は U+0100 から順に）から戻す表
        let printable: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
        let others: [Int] = (0..<256).filter { !printable.contains($0) }
        var decoder: [UInt32: UInt8] = [:]
        for (k, byte) in (printable + others).enumerated() {
            decoder[UInt32(k < printable.count ? byte : 256 + k - printable.count)] = UInt8(byte)
        }
        bytes = (0..<vocabularySize).map { id in (upstream.convertIdToToken(id) ?? "").unicodeScalars.compactMap { decoder[$0.value] } }
    }

    func encode(_ text: String) -> [Int] { upstream.encode(text: text, addSpecialTokens: false) }

    /// 時刻トークンを除いて文字列にする（tiktoken の decode）
    func decode(_ tokens: [Int]) -> String { decodeWithTimestamps(tokens.filter { $0 < timestampBegin }) }

    func decodeWithTimestamps(_ tokens: [Int]) -> String { String(decoding: tokens.flatMap { bytes[$0] }, as: UTF8.self) }

    /// 話し言葉に出ない記号（mlx_whisper の non_speech_tokens）と、途中に出てはいけない特殊トークン。suppress_tokens="-1" の中身
    var suppressTokens: [Int] {
        let single: [String] = "\"#()*+/:;<=>@[\\]^_`{|}~「」『』".map(String.init)
        let multiple: [String] = "<< >> <<< >>> -- --- -( -[ (' (\" (( )) ((( ))) [[ ]] {{ }} ♪♪ ♪♪♪".split(separator: " ").map(String.init)
        let miscellaneous: [String] = "♩♪♫♬♭♮♯".map(String.init)  // 複数トークンになっても最初のトークンだけ抑える
        var result: Set<Int> = [encode(" -")[0], encode(" '")[0]]
        for symbol in single + multiple + miscellaneous {
            for tokens in [encode(symbol), encode(" " + symbol)] where tokens.count == 1 || miscellaneous.contains(symbol) {
                result.insert(tokens[0])
            }
        }
        return result.union([transcribe, translate, sot, sotPrev, sotLM, noSpeech]).sorted()
    }

    /// 語の区切り（日本語などは空白で区切れないので、UTF-8 の文字として読める所ごとに区切る。split_tokens_on_unicode）
    func splitToWordTokens(_ tokens: [Int]) -> (words: [String], tokens: [[Int]]) {
        let replacement: Unicode.Scalar = "\u{FFFD}"
        let full = Array(decodeWithTimestamps(tokens).unicodeScalars)
        var words: [String] = [], wordTokens: [[Int]] = [], current: [Int] = []
        var offset = 0
        for token in tokens {
            current.append(token)
            let decoded = decodeWithTimestamps(current)
            let scalars = Array(decoded.unicodeScalars)
            // 途中までのバイト列（U+FFFD になる）は次のトークンと合わせる。元から U+FFFD の文字はそのまま区切る
            if let k = scalars.firstIndex(of: replacement), offset + k >= full.count || full[offset + k] != replacement { continue }
            words.append(decoded)
            wordTokens.append(current)
            current = []
            offset += scalars.count
        }
        return (words, wordTokens)
    }
}

enum WhisperTextTokenizerError: Error {
    case missingToken(String)
}

