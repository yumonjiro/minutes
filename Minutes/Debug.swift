#if DEBUG
import AppKit

/// 開発用（Debug ビルドだけ）: 環境変数で起動時の画面の状態を決め、ウィンドウの見た目を PNG に書き出す。
/// 画面を人が操作できないときに、表示を自動で確かめるため（open --env で渡す）
///   MINUTES_SNAPSHOT=1|all      2 秒ごとに、各ウィンドウの画面に出ている見た目（ウィンドウサーバーが合成したもの）を
///                               tmp/snapshots/<名前>.png に書き出す。描き直させずに写すので、描き直しが画面に出ているかも分かる。
///                               all なら上書きせず <名前>-<連番>.png に残す
///   MINUTES_TIMELINE=1          タイムラインを開く
///   MINUTES_IMMERSIVE=1|0       没入モードにする・通常の表示にする
///   MINUTES_TEXTSIZE=<段階>      今の表示（通常・没入モード）の文字の大きさの段階（0〜7。標準は 3）
///   MINUTES_SCHEDULE=<秒>:<i か段階>,…  開いてからその秒に、没入モードを切り替える（i）か、今の表示の文字の大きさの段階を変える
///   MINUTES_SEEK=<秒>           その位置に移り（再生はしない）、文字起こしをその発言まで動きを付けずに送る
///                               （画面のロック中は送る動きが進まないため）
///   MINUTES_APPEARANCE=light|dark  ライト表示・ダーク表示にする
///   MINUTES_SEARCH=<語>         文字起こしをこの語で検索する
///   MINUTES_ZOOM=<倍率>         タイムラインをこの倍率に拡大する（再生位置を中心に）
///   MINUTES_SEEKHOVER=<0〜1>    シークバーのその位置にポインタが乗っているときの表示にする
///   MINUTES_SIDEBARHOVER=<番号>  サイドバーのその録音の行にポインタが乗っているときの表示にする
///   MINUTES_NOTES=outline|notes  右のパネルを開き、目次か注釈を出す
///   MINUTES_OPEN=<録音のフォルダ名>  その録音を開く
///   MINUTES_MODE=original|tidied|compare  文字起こしの表示の仕方（原文・整形・見比べ）
///   MINUTES_TIDY=1              開いた録音の整形を始める
///   MINUTES_POINTER=<発言>:<文字>  文字起こしのその文字の上へポインタを動かす（マウスの動きを作って送る。
///                               文字を g にすると、その発言の前の議題を入れる所）
///   MINUTES_DRAG=<発言>:<文字>,<発言>:<文字>  その間をマウスでドラッグして選び（文字を h にすると見出しの左から）、
///                               コピーされる文字を tmp/snapshots/copy.txt に書く
///   MINUTES_PERF=idle|scroll|play  軽さと滑らかさを測る: 起動 4 秒後から 15 秒間、何もしないか（idle）、一番長い一覧を
///                               自動でスクロールするか（scroll）、音を消して 2:20（MINUTES_SEEK があればその位置）から再生し（play）、CPU 使用率と
///                               メインスレッドのフレーム間隔を tmp/snapshots/perf-<名前>.txt に書く（idle は CPU だけ）
enum Debug {
    static let env = ProcessInfo.processInfo.environment

    static var timeline: Bool { env["MINUTES_TIMELINE"] == "1" }
    static var seek: Double? { env["MINUTES_SEEK"].flatMap(Double.init) }
    static var search: String? { env["MINUTES_SEARCH"] }
    static var perf: String? { env["MINUTES_PERF"] }
    static var appearance: NSAppearance? { env["MINUTES_APPEARANCE"].map { NSAppearance(named: $0 == "dark" ? .darkAqua : .aqua)! } }
    static var zoom: CGFloat? { env["MINUTES_ZOOM"].flatMap(Double.init).map { CGFloat($0) } }
    static var seekHover: CGFloat? { env["MINUTES_SEEKHOVER"].flatMap(Double.init).map { CGFloat($0) } }
    static var sidebarHover: Int? { env["MINUTES_SIDEBARHOVER"].flatMap { Int($0) } }

    static let dir = FileManager.default.temporaryDirectory.appending(component: "snapshots")

    static func start() {
        if let appearance { NSApp.appearance = appearance }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let perf {
            Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in MainActor.assumeIsolated { FrameMeter.start(perf) } }
        }
        guard let mode = env["MINUTES_SNAPSHOT"] else { return }
        var count = 0
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                count += 1
                for window in NSApp.windows where window.isVisible {
                    guard let image = locked ? rendered(window) : composited(window) else { continue }
                    let name = (window.title.isEmpty ? "window-\(window.windowNumber)" : window.title) + (mode == "all" ? "-\(count)" : "")
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: dir.appending(component: "\(name).png"))
                }
            }
        }
    }

    /// 文字起こしを初めて表示したとき: ポインタの動き・ドラッグを作って送る（並べ終わるのを待ってから）
    static func transcriptShown(_ view: TranscriptListView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak view] in
            guard let view else { return }
            if let t = seek { view.debugScroll(to: t) }
            if let p = env["MINUTES_POINTER"].flatMap({ point($0, in: view) }) { send(.mouseMoved, at: p, to: view) }
            if let v = env["MINUTES_DRAG"]?.split(separator: ","), v.count == 2,
               let a = point(String(v[0]), in: view), let b = point(String(v[1]), in: view) {
                send(.leftMouseDown, at: a, to: view)
                for i in 1...8 {
                    let f = CGFloat(i) / 8
                    send(.leftMouseDragged, at: CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f), to: view)
                }
                send(.leftMouseUp, at: b, to: view)
                try? (view.selectedText() ?? "（選択なし）").write(to: dir.appending(component: "copy.txt"), atomically: true, encoding: .utf8)
            }
        }
    }

    /// 「発言:文字」の点（文字が h なら見出しの左、g なら発言の前の議題を入れる所）
    private static func point(_ spec: String, in view: TranscriptListView) -> CGPoint? {
        let parts = spec.split(separator: ":")
        guard parts.count == 2, let b = Int(parts[0]) else { return nil }
        switch parts[1] {
        case "h": return view.debugHeaderPoint(block: b)
        case "g": return view.debugGapPoint(block: b)
        default: return Int(parts[1]).flatMap { view.debugPoint(block: b, offset: $0) }
        }
    }

    private static func send(_ type: NSEvent.EventType, at p: CGPoint, to view: NSView) {
        guard let window = view.window,
              let event = NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        default: view.mouseMoved(with: event)
        }
    }
}

/// 画面の更新（ディスプレイのリフレッシュ）ごとに呼ばれる間隔を記録する。メインスレッドが描画の計算で詰まると間隔が延びる
@MainActor
final class FrameMeter: NSObject {
    private static var running: FrameMeter?
    private let name: String
    private var link: CADisplayLink?
    private let started = CACurrentMediaTime()
    private let cpuStart = FrameMeter.cpuTime()
    private var last = CACurrentMediaTime()
    private var intervals: [Double] = []
    private var scroll: NSScrollView?
    private var startHeight: CGFloat = 0
    private var direction: CGFloat = 1

    static func start(_ name: String) {
        guard let view = NSApp.windows.first(where: { $0.isVisible && $0.title != "" })?.contentView else { return }
        let meter = FrameMeter(name: name)
        if name == "scroll" {
            // 文字起こしの一覧の ScrollView、無ければ中身が一番長い ScrollView を毎フレーム一定の速さで送る
            let all = scrollViews(in: view)
            meter.scroll = all.first { $0.documentView is TranscriptListView } ?? all.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
        }
        meter.startHeight = meter.scroll?.documentView?.frame.height ?? 0
        if name == "idle" {
            Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { _ in MainActor.assumeIsolated { meter.finish() } }
        } else {
            meter.link = view.displayLink(target: meter, selector: #selector(step))
            meter.link?.add(to: .main, forMode: .common)
        }
        running = meter
    }

    /// このプロセスが使った CPU 時間（秒、全スレッドの合計）
    private static func cpuTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private init(name: String) { self.name = name }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        intervals.append(now - last)
        if let scroll, let height = scroll.documentView?.frame.height {
            let clip = scroll.contentView, limit = max(0, height - clip.bounds.height)
            var y = clip.bounds.origin.y + direction * 900 * (now - last)
            if y >= limit { y = limit; direction = -1 } else if y <= 0 { y = 0; direction = 1 }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scroll.reflectScrolledClipView(clip)
        }
        last = now
        if now - started > 15 { finish() }
    }

    private func finish() {
        link?.invalidate()
        let cpu = (Self.cpuTime() - cpuStart) / (CACurrentMediaTime() - started) * 100
        let ms = intervals.dropFirst().map { $0 * 1000 }.sorted()
        func p(_ q: Double) -> Double { ms.isEmpty ? 0 : ms[min(ms.count - 1, Int(Double(ms.count) * q))] }
        let summary = String(format: "%@: CPU %.1f%%  %d フレーム  中央値 %.1f ms  95%% %.1f ms  99%% %.1f ms  最大 %.1f ms  25ms超 %d  50ms超 %d  （%@）\n",
                             name, cpu, ms.count, p(0.5), p(0.95), p(0.99), ms.last ?? 0, ms.filter { $0 > 25 }.count, ms.filter { $0 > 50 }.count,
                             scroll.map { "\(type(of: $0)) 高さ \(Int(startHeight)) → \(Int($0.documentView?.frame.height ?? 0))" } ?? "スクロールなし")
        try? summary.write(to: Debug.dir.appending(component: "perf-\(name).txt"), atomically: true, encoding: .utf8)
        Self.running = nil
    }
}

extension Debug {
    /// 自分のウィンドウをウィンドウサーバーから取り込む（自分のウィンドウなら画面収録の許可は要らない）。
    /// CGWindowListCreateImage は新しい SDK では使えなくなったので、実行時に探して呼ぶ
    /// 画面がロックされているか（ロック中はウィンドウサーバーから写せないので、レイヤーから描く）
    static var locked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// ウィンドウのレイヤーを描いた見た目（画面のロック中に使う。すりガラスなど一部の効果は描かれない）
    static func rendered(_ window: NSWindow) -> CGImage? {
        guard let frame = window.contentView?.superview, let layer = frame.layer else { return nil }
        let scale = window.backingScaleFactor, size = frame.bounds.size
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        if frame.isFlipped {
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        layer.render(in: ctx)
        return ctx.makeImage()
    }

    static func composited(_ window: NSWindow) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(sym, to: Capture.self)
        // kCGWindowListOptionIncludingWindow = 1 << 3、kCGWindowImageBoundsIgnoreFraming = 1 << 0
        return capture(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue()
    }
}
#endif
