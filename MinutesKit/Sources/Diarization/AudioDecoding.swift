import Accelerate
import AVFoundation

/// 音声・動画ファイル（m4a・mp3・wav・mp4・mov など AVFoundation が読めるもの）を 16 kHz モノラルの Float32 にする。
/// チャンネルは平均してから（ffmpeg -ac 1 で 16 bit に書き出すときと同じ (L+R)/2）AVAudioConverter でリサンプリングする。
/// 長い録音でもメモリを食わないよう、少しずつ読みながら変換する
public func decodeAudio16kMono(url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)  // 読み出しは Float32・チャンネル別
    let source = file.processingFormat
    let block: AVAudioFrameCount = 1 << 16
    guard let mono = AVAudioFormat(standardFormatWithSampleRate: source.sampleRate, channels: 1),
          let target = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
          let converter = AVAudioConverter(from: mono, to: target),
          let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: block),
          let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: block),
          let downmixed = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: block)
    else { throw DiarizationError("変換できない音声形式です: \(source)") }

    var samples: [Float] = []
    samples.reserveCapacity(Int(Double(file.length) * target.sampleRate / source.sampleRate) + 1)
    while true {
        if file.framePosition < file.length { try file.read(into: input, frameCount: block) } else { input.frameLength = 0 }  // 終端で read するとエラーになる
        let end = input.frameLength == 0
        downmix(input, into: downmixed)
        // 変換器は入力をブロックで受け取る。読んだ分を 1 回だけ渡し、出力バッファが埋まるたびに取り出す
        nonisolated(unsafe) let pending = downmixed
        nonisolated(unsafe) var supplied = end
        var status: AVAudioConverterOutputStatus
        repeat {
            var error: NSError?
            status = converter.convert(to: output, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = end ? .endOfStream : .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return pending
            }
            if status == .error { throw error ?? DiarizationError("音声を変換できません: \(url.path)") }
            samples += UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))
        } while status == .haveData
        if end { return samples }
    }
}

/// チャンネルの平均をモノラルのバッファに書く
private func downmix(_ input: AVAudioPCMBuffer, into mono: AVAudioPCMBuffer) {
    let n = vDSP_Length(input.frameLength), channels = Int(input.format.channelCount)
    let src = input.floatChannelData!, dst = mono.floatChannelData![0]
    dst.update(from: src[0], count: Int(n))
    for c in 1..<max(channels, 1) { vDSP_vadd(dst, 1, src[c], 1, dst, 1, n) }
    if channels > 1 {
        var scale = 1 / Float(channels)
        vDSP_vsmul(dst, 1, &scale, dst, 1, n)
    }
    mono.frameLength = input.frameLength
}
