import AppKit
import MinutesCore
import SwiftUI

/// 下部の再生バー。タイムラインを開くと上に広がり、話者ごとの発話の帯と、今話している人を示す。右端に、タイムラインと没入モードの切り替え
struct PlayerBar: View {
    let player: AudioPlayer
    let model: TranscriptModel
    let recording: Recording
    @Binding var expanded: Bool
    @Binding var immersive: Bool

    private static let rates: [Float] = [1, 1.25, 1.5, 2]

    var body: some View {
        let duration = player.duration > 0 ? player.duration : max(recording.transcript?.progress.totalSec ?? 0, model.duration)
        let notes = model.resolve(recording.notes)
        VStack(spacing: 0) {
            if expanded {
                TimelinePanel(player: player, model: model, recording: recording, notes: notes, duration: duration)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                Divider()
            }
            HStack(spacing: 10) {
                HStack(spacing: 2) {
                    Button("5秒戻る", systemImage: "gobackward.5") { player.skip(-5) }
                        .help("5秒戻る（←）")
                    Button(player.isPlaying ? "一時停止" : "再生", systemImage: player.isPlaying ? "pause.fill" : "play.fill") { player.toggle() }
                        .buttonStyle(PlayButtonStyle())
                        .help("再生 / 一時停止（Space）")
                    Button("5秒進む", systemImage: "goforward.5") { player.skip(5) }
                        .help("5秒進む（→）")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(IconButtonStyle())
                Clock(player: player).frame(minWidth: 40, alignment: .trailing)
                SeekStrip(player: player, model: model, recording: recording, notes: notes, duration: duration)
                Text(formatTime(duration)).frame(minWidth: 40, alignment: .leading)
                Button("\(player.rate.formatted())×") {
                    let rates = Self.rates
                    player.setRate(rates[((rates.firstIndex(of: player.rate) ?? 0) + 1) % rates.count])
                }
                .buttonStyle(IconButtonStyle(width: 46))
                .fontWeight(.semibold)
                .help("再生速度")
                Toggle(isOn: $immersive) { Label("没入モード", systemImage: "quote.bubble") }
                    .toggleStyle(IconToggleStyle())
                    .help(immersive ? "通常の表示に戻す" : "没入モード（今の発言を大きく、前後の発言と一緒に）")
                Toggle(isOn: $expanded) { Label("タイムライン", systemImage: "timeline.selection") }
                    .toggleStyle(IconToggleStyle())
                    .help(expanded ? "タイムラインを閉じる" : "タイムライン（話者ごとの発言の流れ）")
            }
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(height: 60)
        }
        // 最小の幅は 0 にして、中身（ボタンの合計）の幅を外に伝えない。伝えると、右の注釈パネルとの分割の計算がぶつかり、
        // ウィンドウのレイアウトが止まらなくなって落ちることがあった
        .frame(minWidth: 0, maxWidth: 980)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.07), radius: 14, y: 4)
        .animation(.smooth(duration: 0.35), value: expanded)
    }
}

/// 再生位置の時刻（1 秒ごとに描き直す）
private struct Clock: View {
    let player: AudioPlayer
    var body: some View { Text(formatTime(Double(player.second))) }
}

/// シークバー: モノトーンの細い線。見出しの区切りに目盛り、ハイライト（その色）とブックマーク（アクセントの色）に点。
/// ポインタを乗せると、その発言の区間を話者の色で示し、見出し・時刻・話者・注釈を出す。クリック・ドラッグでシーク
private struct SeekStrip: View {
    let player: AudioPlayer
    let model: TranscriptModel
    let recording: Recording
    let notes: ResolvedNotes
    let duration: Double
    @State private var hover: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1), d = max(duration, 0.001)
            let t = hover.map { max(0, min(1, $0 / w)) * d }
            let hovered = t.flatMap { model.block(near: $0, tolerance: Double(SeekTrack.pad / w) * d) }
            ZStack(alignment: .leading) {
                SeekTrack(model: model, duration: d, pending: recording.isProcessing ? recording.transcript?.progress.doneSec : nil, hovered: hovered,
                          sections: notes.headings.map { .init(time: model.blocks[$0.block].start, level: $0.level) },
                          marks: notes.highlights.map { .init(time: model.words[$0.words.lowerBound].start, color: HighlightColor.solid[$0.color]) }
                            + notes.bookmarks.keys.map { .init(time: model.blocks[$0].start, color: nil) })
                    .equatable()
                PlayheadLayer(player: player, duration: d, style: .seek)
                if let hover, let t {
                    // ポインタの真上に出す（両端の近くでは、はみ出さないように片側へ寄せる）
                    let side: Alignment = hover < 90 ? .bottomLeading : hover > w - 90 ? .bottomTrailing : .bottom
                    Color.clear
                        .frame(width: 0, height: 0)
                        .overlay(alignment: side) {
                            SeekTip(time: t, speaker: hovered.map { recording.name(of: model.blocks[$0].speaker) },
                                    section: section(at: t, hovered: hovered), detail: hovered.flatMap(detail))
                        }
                        .position(x: hover < 90 ? max(0, hover - 16) : hover > w - 90 ? min(w, hover + 16) : hover, y: -2)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { player.seek(to: max(0, min(1, $0.location.x / w)) * d) })
            .onContinuousHover { phase in
                if case .active(let p) = phase { hover = p.x } else { hover = nil }
            }
            #if DEBUG
            .onAppear { if let f = Debug.seekHover { hover = f * w } }
            #endif
        }
        .frame(height: 36)
        .accessibilityElement()
        .accessibilityLabel("再生位置")
    }

    /// 時刻 t が入っている見出しの名前
    private func section(at t: Double, hovered: Int?) -> String? {
        guard let b = hovered ?? model.blocks.lastIndex(where: { $0.start <= t }), let h = notes.heading(containing: b) else { return nil }
        return h.title.isEmpty ? "無題の見出し" : h.title
    }

    /// 発言 b の注釈（「★ ブックマーク・決定・TODO」）
    private func detail(_ b: Int) -> String? {
        var parts: [String] = notes.bookmarks[b] != nil ? ["★ ブックマーク"] : []
        for c in Set(notes.highlights(in: model.blocks[b].words).map(\.color)).sorted() { parts.append(HighlightColor.name(c)) }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }
}

/// シークバーの線と目盛り・点、ポインタの乗っている発言の区間。録音・ポインタの乗っている発言・注釈が変わったときだけ描き直す
private struct SeekTrack: View, Equatable {
    /// 発言の区間の高さ、線の太さ、短い発言でも見えるように区間の両端を延ばす長さ
    static let band: CGFloat = 20, line: CGFloat = PlayheadView.lineWidth, pad: CGFloat = 1.5

    /// 見出しの区切り（議題は長い目盛り）と、注釈の点（色がなければブックマーク）
    struct Section: Equatable {
        var time: Double
        var level: Int
    }

    struct Mark: Equatable {
        var time: Double
        var color: NSColor?
    }

    let model: TranscriptModel
    let duration: Double
    /// 処理中なら、文字起こしが済んだ所（秒）
    let pending: Double?
    let hovered: Int?
    let sections: [Section]
    let marks: [Mark]

    static func == (a: Self, b: Self) -> Bool {
        a.model.id == b.model.id && a.duration == b.duration && a.pending == b.pending && a.hovered == b.hovered
            && a.sections == b.sections && a.marks == b.marks
    }

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, px = w / duration, h = Self.band, y = (size.height - h) / 2
            func span(_ a: Double, _ b: Double) -> CGRect {
                CGRect(x: a * px - Self.pad, y: y, width: max(0, (b - a) * px) + Self.pad * 2, height: h)
            }
            ctx.drawLayer { ctx in
                if let hovered, model.blocks.indices.contains(hovered) {
                    let b = model.blocks[hovered], r = span(b.start, b.end)
                    ctx.fill(Path(roundedRect: r, cornerRadius: min(4, r.width / 2)), with: .color((model.colors[b.speaker] ?? .gray).opacity(0.6)))
                }
                // 線（まだ再生していない部分。再生済みの部分は PlayheadView が上に重ねる）
                ctx.fill(Path(roundedRect: CGRect(x: 0, y: (size.height - Self.line) / 2, width: w, height: Self.line), cornerRadius: Self.line / 2),
                         with: .color(.secondary.opacity(0.3)))
                if let pending {
                    let x = pending * px, rest = CGRect(x: x, y: y, width: w - x, height: h)
                    var stripes = Path()
                    var sx = x - h
                    while sx < w { stripes.move(to: CGPoint(x: sx, y: y + h)); stripes.addLine(to: CGPoint(x: sx + h, y: y)); sx += 6 }
                    ctx.clip(to: Path(roundedRect: rest, cornerRadius: 5))
                    ctx.fill(Path(rest), with: .color(Color(nsColor: .controlBackgroundColor)))
                    ctx.stroke(stripes, with: .color(.secondary.opacity(0.35)), lineWidth: 1.5)
                }
            }
            let mid = size.height / 2
            for s in sections {
                let h: CGFloat = s.level == 1 ? 14 : 8
                ctx.fill(Path(roundedRect: CGRect(x: s.time * px - 0.75, y: mid - h / 2, width: 1.5, height: h), cornerRadius: 0.75),
                         with: .color(.primary.opacity(0.45)))
            }
            for m in marks {
                ctx.fill(Path(ellipseIn: CGRect(x: m.time * px - 2.5, y: mid - 13, width: 5, height: 5)),
                         with: .color(m.color.map { Color(nsColor: $0) } ?? .accentColor))
            }
        }
    }
}

/// シークバーの上に出す、ポインタの位置の見出し・時刻・話者・注釈
private struct SeekTip: View {
    let time: Double
    let speaker: String?
    let section: String?
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let section { Text(section).fontWeight(.semibold) }
            Text(formatTime(time) + (speaker.map { "  " + $0 } ?? ""))
            if let detail { Text(detail) }
        }
        .font(.caption2.monospacedDigit())
        .lineLimit(1)
        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.primary, in: RoundedRectangle(cornerRadius: 5))
        .fixedSize()
    }
}

struct PlayheadLayer: NSViewRepresentable {
    let player: AudioPlayer
    let duration: Double
    let style: PlayheadView.Style

    func makeNSView(context: Context) -> PlayheadView { PlayheadView(player: player, style: style) }

    func updateNSView(_ view: PlayheadView, context: Context) {
        view.duration = duration
    }
}

/// 再生位置の印。再生中は Core Animation が等速で動かすので、アプリは毎フレーム描き直さない。
/// シーク・再生・一時停止・速度の変更のときだけ（AudioPlayer の anchor などが変わったとき）、その時点の再生位置に合わせ直す。
/// この表示の幅がちょうど録音全体に当たる（タイムラインで拡大したときは、見えている所より広い）
final class PlayheadView: NSView {
    enum Style {
        /// シークバー: 再生済みの部分の線と、今の位置のつまみ
        case seek
        /// タイムライン: 上に丸の付いた縦線
        case timeline
    }

    /// シークバーの線の太さと、つまみの大きさ
    static let lineWidth: CGFloat = 4, knobSize: CGFloat = 12

    private struct Sync: Equatable {
        var time: Double
        var rate: Double
        var anchor: Int
    }

    private let player: AudioPlayer
    private let style: Style
    private let line = CALayer(), knob = CALayer()
    private var sync = Sync(time: 0, rate: 0, anchor: -1)
    private var synced = CACurrentMediaTime()

    /// 録音の長さ（秒）
    var duration: Double = 1 { didSet { if duration != oldValue { place() } } }

    init(player: AudioPlayer, style: Style) {
        self.player = player
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        switch style {
        case .seek:
            line.anchorPoint = CGPoint(x: 0, y: 0.5)
            line.cornerRadius = Self.lineWidth / 2
            knob.cornerRadius = Self.knobSize / 2
            knob.borderWidth = 2
        case .timeline:
            knob.cornerRadius = 4
        }
        layer?.addSublayer(line)
        layer?.addSublayer(knob)
        applyColors()
        observePlayer()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { place() }
    }

    override func viewDidChangeEffectiveAppearance() { applyColors() }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            line.backgroundColor = NSColor.labelColor.cgColor
            knob.backgroundColor = NSColor.labelColor.cgColor
            knob.borderColor = NSColor.controlBackgroundColor.cgColor
        }
    }

    /// 再生位置・再生中かどうか・速さが変わったときだけ合わせ直す（再生中の時刻の進みは見ない）
    private func observePlayer() {
        let s = withObservationTracking {
            Sync(time: player.exactTime, rate: player.isPlaying ? Double(player.rate) : 0, anchor: player.anchor)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePlayer() }
        }
        guard s != sync else { return }
        sync = s
        synced = CACurrentMediaTime()
        place()
    }

    /// 今の再生位置に置き、再生中なら最後まで等速で動くアニメーションを付ける
    private func place() {
        let w = bounds.width, h = bounds.height, d = max(duration, 0.001)
        let now = min(d, sync.time + (CACurrentMediaTime() - synced) * sync.rate)
        let x = CGFloat(now / d) * w
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.removeAllAnimations()
        knob.removeAllAnimations()
        switch style {
        case .seek:
            line.bounds = CGRect(x: 0, y: 0, width: x, height: Self.lineWidth)
            line.position = CGPoint(x: 0, y: h / 2)
            knob.bounds = CGRect(x: 0, y: 0, width: Self.knobSize, height: Self.knobSize)
            knob.position = CGPoint(x: x, y: h / 2)
        case .timeline:
            line.bounds = CGRect(x: 0, y: 0, width: 2, height: h)
            line.position = CGPoint(x: x, y: h / 2)
            knob.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
            knob.position = CGPoint(x: x, y: 0)
        }
        CATransaction.commit()
        guard sync.rate > 0, now < d, w > 0 else { return }
        let remaining = (d - now) / sync.rate
        func animate(_ layer: CALayer, _ keyPath: String, to value: CGFloat) {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = layer.value(forKeyPath: keyPath)
            animation.toValue = value
            animation.duration = remaining
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            layer.add(animation, forKey: keyPath)
        }
        animate(knob, "position.x", to: w)
        if style == .seek { animate(line, "bounds.size.width", to: w) } else { animate(line, "position.x", to: w) }
    }
}

/// 再生ボタン（塗りつぶしの丸）
private struct PlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(Color(nsColor: .controlBackgroundColor))
            .frame(width: 40, height: 40)
            .background(.primary, in: Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .contentShape(Circle())
    }
}

private struct IconToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            configuration.label.labelStyle(.iconOnly)
                .foregroundStyle(configuration.isOn ? Color.accentColor : .secondary)
                .frame(width: 32, height: 30)
                .background(configuration.isOn ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .font(.system(size: 15))
    }
}
