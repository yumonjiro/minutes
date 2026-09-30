import Accelerate

/// NeMo の AudioToMelSpectrogramPreprocessor（Nemotron-3-Diarization の設定）と同じ log-mel 特徴量。
/// プリエンファシス 0.97 → STFT（n_fft 512・長さ 400 の対称 Hann 窓・ホップ 160・中央揃えで両端をゼロ埋め）→
/// パワー → Slaney のメルフィルタ 128 本 → log(x + 2^-24)。正規化なし（normalize: NA）、推論時はディザなし。
/// 窓とメルフィルタはチェックポイント（bf16）に保存された値なので bfloat16 に丸める（丸めないと特徴量が 0.2% ほどずれる）。
/// 正規化がないので各フレームは近くの標本だけで決まり、チャンクごとに必要な範囲だけ計算できる
struct LogMel {
    static let bins = 128
    private static let hop = 160, nFFT = 512, windowLength = 400, freqs = nFFT / 2 + 1

    private let window: [Float]  // n_fft の中央に置いた窓（torch.stft と同じ）
    private let filters: [Float]  // [freqs][bins]
    private let dft: vDSP.DiscreteFourierTransform<Float>

    init() throws {
        let offset = (Self.nFFT - Self.windowLength) / 2
        window = (0..<Self.nFFT).map { i in
            let n = i - offset
            guard n >= 0 && n < Self.windowLength else { return 0 }
            return bfloat16(Float(0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(Self.windowLength - 1))))
        }
        filters = Self.slaneyFilters()
        dft = try vDSP.DiscreteFourierTransform(count: Self.nFFT, direction: .forward, transformType: .complexReal, ofType: Float.self)
    }

    /// 有効なフレーム数（NeMo の seq_len）と、特徴量の全長（STFT のフレーム数を pad_to=16 の倍数に揃えたもの）
    static func frameCounts(samples: Int) -> (valid: Int, total: Int) {
        let valid = samples / hop
        return (valid, (valid + 1 + 15) / 16 * 16)
    }

    /// frames の特徴量を [フレーム][bins] で返す。valid 以降のフレームは 0（NeMo の pad_value）
    func callAsFunction(_ x: [Float], frames: Range<Int>, valid: Int) -> [Float] {
        let count = min(frames.upperBound, valid) - frames.lowerBound
        let padding = [Float](repeating: 0, count: (frames.count - max(count, 0)) * Self.bins)
        guard count > 0 else { return padding }
        // フレーム t は標本 [t*hop - nFFT/2, t*hop + nFFT/2) を見る。範囲外は 0（STFT の定数パディング）
        let first = frames.lowerBound * Self.hop - Self.nFFT / 2
        var y = [Float](repeating: 0, count: (count - 1) * Self.hop + Self.nFFT)
        for i in max(first, 0)..<min(first + y.count, x.count) {
            y[i - first] = i == 0 ? x[0] : x[i] - 0.97 * x[i - 1]  // プリエンファシス
        }
        let half = Self.nFFT / 2
        var power = [Float](repeating: 0, count: count * Self.freqs)
        var re = [Float](repeating: 0, count: half), im = re, outRe = re, outIm = re
        for f in 0..<count {
            let o = f * Self.hop
            for j in 0..<half {  // 実数の DFT には偶数番目を実部、奇数番目を虚部に詰めて渡す
                re[j] = y[o + 2 * j] * window[2 * j]
                im[j] = y[o + 2 * j + 1] * window[2 * j + 1]
            }
            dft.transform(inputReal: re, inputImaginary: im, outputReal: &outRe, outputImaginary: &outIm)
            // vDSP の出力は 2 倍で、直流とナイキストは outRe[0]・outIm[0] に入る
            let p = f * Self.freqs
            power[p] = outRe[0] * outRe[0] / 4
            power[p + half] = outIm[0] * outIm[0] / 4
            for k in 1..<half { power[p + k] = (outRe[k] * outRe[k] + outIm[k] * outIm[k]) / 4 }
        }
        var mel = [Float](repeating: 0, count: count * Self.bins)
        vDSP_mmul(power, 1, filters, 1, &mel, 1, vDSP_Length(count), vDSP_Length(Self.bins), vDSP_Length(Self.freqs))
        return vForce.log(vDSP.add(0x1p-24, mel)) + padding
    }

    /// librosa.filters.mel(sr=16000, n_fft=512, n_mels=128, norm="slaney") を転置したもの
    private static func slaneyFilters() -> [Float] {
        // Slaney のメル尺度: 1 kHz までは線形、それより上は対数
        let fSp = 200.0 / 3, minLogMel = 1000 / fSp, logStep = log(6.4) / 27
        func mel(_ hz: Double) -> Double { hz < 1000 ? hz / fSp : minLogMel + log(hz / 1000) / logStep }
        func hz(_ mel: Double) -> Double { mel < minLogMel ? mel * fSp : 1000 * exp(logStep * (mel - minLogMel)) }
        let top = mel(8000), step = top / Double(bins + 1)
        let edges = (0...(bins + 1)).map { hz($0 == bins + 1 ? top : Double($0) * step) }  // numpy.linspace と同じ
        var filters = [Float](repeating: 0, count: freqs * bins)
        for m in 0..<bins {
            let norm = 2 / (edges[m + 2] - edges[m])
            for k in 0..<freqs {
                let f = Double(k) * 16000 / Double(nFFT)
                let w = max(0, min((f - edges[m]) / (edges[m + 1] - edges[m]), (edges[m + 2] - f) / (edges[m + 2] - edges[m + 1])))
                filters[k * bins + m] = bfloat16(Float(Double(Float(w)) * norm))  // librosa は三角形を float32 にしてから正規化する
            }
        }
        return filters
    }
}

/// bfloat16 に丸める（最近接偶数丸め。torch の Tensor.bfloat16() と同じ）
private func bfloat16(_ x: Float) -> Float {
    let bits = x.bitPattern
    return Float(bitPattern: (bits &+ 0x7FFF &+ ((bits >> 16) & 1)) & 0xFFFF_0000)
}
