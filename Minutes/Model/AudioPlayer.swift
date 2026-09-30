import AVFoundation
import MinutesCore
import Observation

/// 録音の再生。再生中は 1/30 秒ごとに currentTime を更新する。
/// 吹き出しやタイムラインは変わったときだけ更新される値（currentWord・currentBlock・shownBlock・talking・second）を見て、
/// 毎フレーム描き直さないようにする。再生位置の線は Core Animation が動かし、anchor が変わったとき（シーク・再生・一時停止・
/// 速度の変更）だけ exactTime に合わせ直す
@Observable
final class AudioPlayer {
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var rate: Float = 1
    private(set) var currentWord: Int?
    /// 開始が再生位置より前の最後の単語（発話の合間でも、話し終えた所までを示す）
    private(set) var spokenWord: Int?
    private(set) var currentBlock: Int?
    /// 今の発言、発言の合間なら直前の発言
    private(set) var shownBlock: Int?
    /// 今話している話者（話者分離の区間が再生位置を含む）
    private(set) var talking: Set<String> = []
    /// 再生位置（秒、整数）。1 秒ごとの処理用
    private(set) var second = 0
    /// 再生位置が飛んだ・動き方が変わった回数（シーク・再生・一時停止・速度の変更・最後まで再生）
    private(set) var anchor = 0

    @ObservationIgnored var model: TranscriptModel? { didSet { updatePosition() } }
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    func load(_ url: URL) {
        stop()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        Task {
            if let d = try? await item.asset.load(.duration), d.seconds.isFinite { duration = d.seconds }
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
                self?.anchor += 1
            }
        }
    }

    func stop() {
        player?.pause()
        if let observer { player?.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        observer = nil
        endObserver = nil
        player = nil
        isPlaying = false
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard let player else { return }
        if duration > 0 && currentTime >= duration - 0.05 { seek(to: 0) }
        player.defaultRate = rate
        player.play()
        isPlaying = true
        anchor += 1
    }

    func pause() {
        player?.pause()
        isPlaying = false
        anchor += 1
    }

    func seek(to t: Double, play shouldPlay: Bool = false) {
        let t = max(0, min(t, duration > 0 ? duration : t))
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        tick(t)
        anchor += 1
        if shouldPlay { play() }
    }

    func skip(_ seconds: Double) { seek(to: currentTime + seconds) }

    /// 今の再生位置をその場で読む（再生中は AVPlayer から。止まっているときは currentTime）
    var exactTime: Double {
        guard isPlaying, let t = player?.currentTime().seconds, t.isFinite else { return currentTime }
        return t
    }

    #if DEBUG
    /// 開発用: 音を出さずに再生する（MINUTES_PERF=play）
    func mute() { player?.isMuted = true }
    #endif

    func setRate(_ r: Float) {
        rate = r
        player?.defaultRate = r
        if isPlaying { player?.rate = r }
        anchor += 1
    }

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        currentTime = t
        updatePosition()
    }

    private func updatePosition() {
        let t = currentTime
        let spoken = model?.lastStarted(t)
        let word = model?.wordAt(t)
        let block = word.map { model!.words[$0].block } ?? model?.blockAt(t)
        let shown = block ?? model?.blocks.lastIndex { $0.start <= t }
        let talking = model?.talking(at: t) ?? []
        if word != currentWord { currentWord = word }
        if spoken != spokenWord { spokenWord = spoken }
        if block != currentBlock { currentBlock = block }
        if shown != shownBlock { shownBlock = shown }
        if talking != self.talking { self.talking = talking }
        if Int(t) != second { second = Int(t) }
    }
}
