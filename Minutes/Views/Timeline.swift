import AppKit
import MinutesCore
import SwiftUI

/// タイムライン: 左に話者の一覧（名前の変更・発話の割合・話し中）、右に話者ごとの発話区間と再生位置。
/// 時間の軸はピンチ（⌘・⌥ + スクロールでも）で拡大・縮小し、横スクロールで動かす
struct TimelinePanel: View {
    let player: AudioPlayer
    let model: TranscriptModel
    let recording: Recording
    let notes: ResolvedNotes
    let duration: Double
    @State private var zoom = TimelineZoom()
    @State private var editing: String?
    @State private var newName = ""

    var body: some View {
        let talking = player.talking
        let total = max(model.talk.values.reduce(0, +), 0.001)
        let height = LanesView.rulerHeight + CGFloat(model.speakers.count) * LanesView.rowHeight
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("話者とタイムライン").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                ZoomControls(zoom: zoom)
            }
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: LanesView.rulerHeight)
                        ForEach(model.speakers, id: \.self) { sp in
                            speakerRow(sp, talking: talking.contains(sp), share: (model.talk[sp] ?? 0) / total)
                        }
                    }
                    .frame(width: 210)
                    Lanes(player: player, model: model, duration: duration, zoom: zoom,
                          sections: notes.headings.map { (model.blocks[$0.block].start, $0.level) },
                          marks: notes.highlights.map { (model.words[$0.words.lowerBound].start, HighlightColor.solid[$0.color]) }
                            + notes.bookmarks.keys.map { (model.blocks[$0].start, NSColor.controlAccentColor) })
                        .frame(height: height)
                }
            }
            .frame(maxHeight: min(height, 320))
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private func speakerRow(_ sp: String, talking: Bool, share: Double) -> some View {
        let color = model.colors[sp] ?? .gray
        return HStack(spacing: 9) {
            Circle().fill(color).frame(width: 10, height: 10)
            if editing == sp {
                TextField("名前", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { recording.rename(speaker: sp, to: newName); editing = nil }
                    .onExitCommand { editing = nil }
            } else {
                Button(recording.name(of: sp)) { newName = recording.name(of: sp); editing = sp }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: talking ? .bold : .medium))
                    .lineLimit(1)
                    .help("クリックで名前を変更")
                Spacer(minLength: 4)
                Text(talking ? "話し中" : "\(Int((share * 100).rounded()))%")
                    .font(.system(size: 11, weight: talking ? .bold : .regular))
                    .foregroundStyle(talking ? AnyShapeStyle(color) : AnyShapeStyle(.tertiary))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: LanesView.rowHeight)
        .background(talking ? color.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .animation(.easeOut(duration: 0.2), value: talking)
    }
}

/// タイムラインの拡大率（1 は録音全体が入る）。ボタンは表示中の LanesView を動かし、LanesView は変わった拡大率をここに書く
@Observable
final class TimelineZoom {
    fileprivate(set) var factor: CGFloat = 1
    fileprivate(set) var limit: CGFloat = 1
    @ObservationIgnored fileprivate weak var view: LanesView?

    func zoom(by f: CGFloat) { view?.zoom(to: factor * f, animated: true) }
    func fit() { view?.zoom(to: 1, animated: true) }
}

/// 縮小・今の拡大率（押すと全体）・拡大。ピンチの間も表示が追いつくよう、拡大率を見るのはこの小さな表示だけにする
private struct ZoomControls: View {
    let zoom: TimelineZoom

    var body: some View {
        let fit = zoom.factor < 1.01
        HStack(spacing: 2) {
            Button("縮小", systemImage: "minus") { zoom.zoom(by: 0.5) }
                .disabled(fit)
                .help("縮小（ピンチ・⌘ + スクロールでも）")
            Button(fit ? "全体" : String(format: zoom.factor < 10 ? "×%.1f" : "×%.0f", zoom.factor)) { zoom.fit() }
                .font(.caption)
                .monospacedDigit()
                .disabled(fit)
                .help("全体を表示")
            Button("拡大", systemImage: "plus") { zoom.zoom(by: 2) }
                .disabled(zoom.factor > zoom.limit - 0.01)
                .help("拡大（ピンチ・⌘ + スクロールでも）")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(IconButtonStyle(width: 28))
    }
}

private struct Lanes: NSViewRepresentable {
    let player: AudioPlayer
    let model: TranscriptModel
    let duration: Double
    let zoom: TimelineZoom
    let sections: [(time: Double, level: Int)]
    let marks: [(time: Double, color: NSColor)]

    func makeNSView(context: Context) -> LanesView { LanesView(player: player, zoom: zoom) }

    func updateNSView(_ view: LanesView, context: Context) {
        view.show(model: model, duration: duration)
        view.annotate(sections: sections, marks: marks)
    }
}

/// タイムラインの帯と目盛り。見えている時間の範囲だけを描くので、拡大しても重くならない（録音全体の幅の絵は作らない）。
/// 同じ話者の区間の間が無音（ほかの話者が話していない）なら、両端を 3pt ずつ延ばして描き、重なったものを 1 本にまとめる。
/// 間が画面の上で 6pt より狭ければつながって見え、拡大して間が開くと、その分だけ隙間が見えてくる（ある拡大率で急に分かれない）。
/// 間でほかの話者が話していたら、つなげない（話者が入れ替わった所は分けて見せる）。
/// 再生中は、再生位置が右端に近づいたら先へ送る（再生位置を見ていないとき、つまり自分で動かして外したときは送らない）
final class LanesView: NSView {
    static let rowHeight: CGFloat = 36, rulerHeight: CGFloat = 24
    /// 区間の両端を延ばす長さ
    private static let pad: CGFloat = 3
    /// 一番拡大したときの 1 秒の幅
    private static let maxPointsPerSecond: CGFloat = 40
    private static let rulerText: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor,
    ]

    private struct Row {
        var speaker: String
        var color: NSColor
        var turns: [(start: Double, end: Double)]
        /// 区間 i と i+1 の間が無音か（つなげてよいか）
        var joins: [Bool]
    }

    private let player: AudioPlayer
    private let zoomState: TimelineZoom
    private let playhead: PlayheadView
    private var modelID: UUID?
    private var rows: [Row] = []
    private var duration: Double = 1
    /// 見出しの区切り（時刻と段）と、注釈の点（時刻と色）
    private var sections: [(time: Double, level: Int)] = []
    private var marks: [(time: Double, color: NSColor)] = []
    private var talking: Set<String> = []
    /// 拡大率（1 は録音全体が入る）と、左端の時刻（秒）
    private var zoom: CGFloat = 1
    private var start: Double = 0
    /// 最後に再生位置が飛んだ・動き方が変わったときの、再生位置・時計・速さ（止まっていれば 0）
    private var anchor = -1, anchorTime: Double = 0, anchorClock = CACurrentMediaTime(), anchorRate: Double = 0
    private var animation: (from: (start: Double, span: Double), to: (start: Double, span: Double), begin: CFTimeInterval)?
    private var link: CADisplayLink?

    init(player: AudioPlayer, zoom: TimelineZoom) {
        self.player = player
        zoomState = zoom
        playhead = PlayheadView(player: player, style: .timeline)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        clipsToBounds = true
        addSubview(playhead)
        zoom.view = self
        observePlayer()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(model: TranscriptModel, duration: Double) {
        if model.id != modelID {
            modelID = model.id
            // 始まりの順に並べた全員の区間と、そこまでの終わりの最大（間にほかの話者の区間がかかるかを二分探索で調べる）
            let all = model.turns.sorted { $0.start < $1.start }
            let starts = all.map(\.start)
            var latest = -Double.infinity
            let latestEnd = all.map { latest = max(latest, $0.end); return latest }
            func silent(from a: Double, to b: Double) -> Bool {
                var lo = 0, hi = starts.count
                while lo < hi {
                    let m = (lo + hi) / 2
                    if starts[m] < b { lo = m + 1 } else { hi = m }
                }
                return lo == 0 || latestEnd[lo - 1] <= a + 0.001
            }
            rows = model.speakers.map { sp in
                let turns = all.filter { $0.speaker == sp }.map { (start: $0.start, end: $0.end) }
                return Row(speaker: sp, color: model.nsColors[sp] ?? .secondaryLabelColor, turns: turns,
                           joins: zip(turns, turns.dropFirst()).map { silent(from: $0.end, to: $1.start) })
            }
            needsDisplay = true
        }
        let d = max(duration, 0.001)
        if d != self.duration {
            self.duration = d
            apply(start: start, zoom: zoom)
        }
    }

    func annotate(sections: [(time: Double, level: Int)], marks: [(time: Double, color: NSColor)]) {
        guard !sections.elementsEqual(self.sections, by: { $0 == $1 }) || !marks.elementsEqual(self.marks, by: { $0.time == $1.time && $0.color == $1.color })
        else { return }
        self.sections = sections
        self.marks = marks
        needsDisplay = true
    }

    // MARK: 見えている範囲

    /// 見えている長さ（秒）と、1 秒の幅
    private var span: Double { duration / Double(zoom) }
    private var scale: CGFloat { bounds.width / CGFloat(span) }
    private var limit: CGFloat { max(1, Self.maxPointsPerSecond * CGFloat(duration) / max(bounds.width, 1)) }

    private func x(_ t: Double) -> CGFloat { CGFloat(t - start) * scale }

    /// 拡大率を z にする。位置 around（x。省略すると、見えていれば再生位置、なければ中央）の時刻は同じ位置のまま
    func zoom(to z: CGFloat, around: CGFloat? = nil, animated: Bool = false) {
        guard bounds.width > 0 else { return }
        let z = min(max(1, z), limit)
        let playing = x(player.exactTime)
        let ax = around ?? ((0...bounds.width).contains(playing) ? playing : bounds.width / 2)
        let t = start + Double(ax / scale), newSpan = duration / Double(z)
        let target = (start: t - Double(ax / bounds.width) * newSpan, zoom: z)
        if animated { animate(to: target) } else { apply(start: target.start, zoom: target.zoom) }
    }

    private func apply(start s: Double, zoom z: CGFloat) {
        zoom = min(max(1, z), limit)
        start = min(max(0, s), max(0, duration - span))
        needsDisplay = true
        playhead.duration = duration
        playhead.frame = CGRect(x: -CGFloat(start) * scale, y: Self.rulerHeight - 6,
                                width: CGFloat(duration) * scale, height: max(0, bounds.height - Self.rulerHeight + 6))
        if zoomState.factor != zoom { zoomState.factor = zoom }
        if zoomState.limit != limit { zoomState.limit = limit }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        apply(start: start, zoom: zoom)
        #if DEBUG
        if let z = Debug.zoom, zoom == 1, newSize.width > 0 { zoom(to: z) }
        #endif
    }

    /// 見えている範囲を滑らかに動かす（両端の時刻を 0.3 秒かけて動かす）
    private func animate(to target: (start: Double, zoom: CGFloat)) {
        let to = (start: min(max(0, target.start), max(0, duration - duration / Double(target.zoom))), span: duration / Double(target.zoom))
        animation = (from: (start, span), to: to, begin: CACurrentMediaTime())
        if link == nil {
            link = displayLink(target: self, selector: #selector(step))
            link?.add(to: .main, forMode: .common)
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let a = animation else { return stopAnimation() }
        let p = min(1, (CACurrentMediaTime() - a.begin) / 0.3), e = p * p * (3 - 2 * p)
        let s = a.from.start + (a.to.start - a.from.start) * e, sp = a.from.span + (a.to.span - a.from.span) * e
        apply(start: s, zoom: CGFloat(duration / sp))
        if p >= 1 { stopAnimation() }
    }

    private func stopAnimation() {
        link?.invalidate()
        link = nil
        animation = nil
    }

    // MARK: 再生に合わせる

    /// 話し中の話者が変わったら描き直し、1 秒ごとに送るかを決め、シークや再生の開始では再生位置を見せる
    private func observePlayer() {
        let (_, anchor, talking) = withObservationTracking {
            (player.second, player.anchor, player.talking)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePlayer() }
        }
        if talking != self.talking {
            self.talking = talking
            needsDisplay = true
        }
        let t = player.exactTime, now = CACurrentMediaTime()
        let moved = anchor != self.anchor
        // 再生を始めたか、再生位置が飛んだ（止めただけ・速さを変えただけではない）
        let jumped = moved && (abs(t - (anchorTime + (now - anchorClock) * anchorRate)) > 0.5 || (player.isPlaying && anchorRate == 0))
        if moved {
            self.anchor = anchor
            (anchorTime, anchorClock, anchorRate) = (t, now, player.isPlaying ? Double(player.rate) : 0)
        }
        guard zoom > 1.001, bounds.width > 0 else { return }
        let px = x(t)
        if jumped {
            if px < 0 || px > bounds.width { animate(to: (t - span * 0.1, zoom)) }
        } else if !moved, player.isPlaying, px > bounds.width * 0.85, px < bounds.width + scale * 2 {
            animate(to: (t - span * 0.1, zoom))
        }
    }

    // MARK: 操作

    override func magnify(with event: NSEvent) {
        stopAnimation()
        zoom(to: zoom * (1 + event.magnification), around: convert(event.locationInWindow, from: nil).x)
    }

    /// 2 本指のダブルタップで、全体とその位置の拡大を切り替える
    override func smartMagnify(with event: NSEvent) {
        zoom(to: zoom > 1.01 ? 1 : 8, around: convert(event.locationInWindow, from: nil).x, animated: true)
    }

    /// 横スクロールで動かし、⌘・⌥ + スクロールで拡大・縮小する。縦のスクロールは外側（話者が多いときの縦の一覧）へ
    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        if !event.modifierFlags.intersection([.command, .option]).isEmpty {
            stopAnimation()
            zoom(to: zoom * CGFloat(exp(Double(dy) * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1))), around: convert(event.locationInWindow, from: nil).x)
        } else if abs(dx) > abs(dy), zoom > 1.001 {
            stopAnimation()
            apply(start: start - Double(dx / scale), zoom: zoom)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) { seek(event) }
    override func mouseDragged(with event: NSEvent) { seek(event) }

    private func seek(_ event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        player.seek(to: min(max(0, start + Double(x / scale)), duration))
    }

    // MARK: 描き方

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, bounds.width > 0 else { return }
        let w = bounds.width
        // 目盛り（目盛りの間が 64pt 以上になる一番細かい刻み）と、その間の補助の刻み（16pt 以上になる一番細かい刻み）
        let steps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200]
        let step = steps.first { CGFloat($0) * scale >= 64 } ?? 7200
        let minor = steps.first { $0 < step && step.truncatingRemainder(dividingBy: $0) == 0 && CGFloat($0) * scale >= 16 }
        let ticks = Array(stride(from: (start / step).rounded(.down) * step, through: start + span, by: step))
        // 補助線: 話者の行の所にも、目盛りの位置に縦の線（補助の刻みはもっと薄く）
        let lanes = CGRect(x: 0, y: Self.rulerHeight, width: w, height: bounds.height - Self.rulerHeight)
        if let minor {
            ctx.setFillColor(NSColor.labelColor.withAlphaComponent(0.035).cgColor)
            for k in stride(from: (start / minor).rounded(.down) * minor, through: start + span, by: minor)
            where k.truncatingRemainder(dividingBy: step) != 0 {
                ctx.fill(CGRect(x: x(k).rounded(), y: lanes.minY, width: 1, height: lanes.height))
                ctx.fill(CGRect(x: x(k).rounded(), y: 13, width: 1, height: 5))
            }
        }
        ctx.setFillColor(NSColor.labelColor.withAlphaComponent(0.08).cgColor)
        for k in ticks { ctx.fill(CGRect(x: x(k).rounded(), y: lanes.minY, width: 1, height: lanes.height)) }
        // 話し中の話者の行
        for (row, r) in rows.enumerated() where talking.contains(r.speaker) {
            ctx.setFillColor(r.color.withAlphaComponent(0.08).cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: Self.rulerHeight + CGFloat(row) * Self.rowHeight, width: w, height: Self.rowHeight),
                               cornerWidth: 8, cornerHeight: 8, transform: nil))
            ctx.fillPath()
        }
        // 話者ごとの区間（見えている所だけ。近い区間はつなげる）
        for (row, r) in rows.enumerated() {
            let y = Self.rulerHeight + CGFloat(row) * Self.rowHeight + 10
            var run: (a: CGFloat, b: CGFloat)?
            func flush() {
                guard let run else { return }
                let rect = CGRect(x: run.a, y: y, width: run.b - run.a, height: 16), radius = min(4, rect.width / 2)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            }
            for (k, turn) in r.turns.enumerated() {
                let joinPrev = k > 0 && r.joins[k - 1], joinNext = k < r.joins.count && r.joins[k]
                var a = x(turn.start) - (joinPrev ? Self.pad : 0), b = x(turn.end) + (joinNext ? Self.pad : 0)
                if b - a < 3 { (a, b) = ((a + b) / 2 - 1.5, (a + b) / 2 + 1.5) }  // 短い区間も見えるように
                if b < 0 { continue }
                if a > w { break }
                if let last = run, joinPrev, a <= last.b { run = (last.a, max(last.b, b)) } else { flush(); run = (a, b) }
            }
            flush()
            ctx.setFillColor(r.color.withAlphaComponent(0.8).cgColor)
            ctx.fillPath()
        }
        // 目盛り
        ctx.setFillColor(NSColor.secondaryLabelColor.withAlphaComponent(0.35).cgColor)
        for k in ticks { ctx.fill(CGRect(x: x(k).rounded(), y: 4, width: 1, height: 14)) }
        for k in ticks { NSAttributedString(string: formatTime(k), attributes: Self.rulerText).draw(at: CGPoint(x: x(k).rounded() + 4, y: 4)) }
        // 見出しの区切り（議題は濃い線と上の三角、小見出しは薄い線）と、注釈の点（目盛りの下の端）
        for s in sections where (-4...w + 4).contains(x(s.time)) {
            let sx = x(s.time).rounded()
            ctx.setFillColor(NSColor.labelColor.withAlphaComponent(s.level == 1 ? 0.45 : 0.2).cgColor)
            ctx.fill(CGRect(x: sx - 0.5, y: Self.rulerHeight - 2, width: 1, height: bounds.height - Self.rulerHeight + 2))
            if s.level == 1 {
                ctx.move(to: CGPoint(x: sx - 4, y: Self.rulerHeight - 8))
                ctx.addLine(to: CGPoint(x: sx + 4, y: Self.rulerHeight - 8))
                ctx.addLine(to: CGPoint(x: sx, y: Self.rulerHeight - 3))
                ctx.closePath()
                ctx.fillPath()
            }
        }
        for m in marks where (-3...w + 3).contains(x(m.time)) {
            ctx.setFillColor(m.color.cgColor)
            ctx.fillEllipse(in: CGRect(x: x(m.time) - 2.5, y: Self.rulerHeight - 6, width: 5, height: 5))
        }
        // 拡大しているときは、録音全体のうち今見ている範囲を、目盛りの上に細い線で示す（話者が多くて縦にスクロールしても見える所）
        if zoom > 1.001 {
            let thumb = CGRect(x: CGFloat(start / duration) * w, y: 0, width: max(24, w / zoom), height: 3)
            ctx.setFillColor(NSColor.secondaryLabelColor.withAlphaComponent(0.4).cgColor)
            ctx.addPath(CGPath(roundedRect: thumb, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
            ctx.fillPath()
        }
    }
}
