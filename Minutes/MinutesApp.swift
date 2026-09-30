import AppKit
import SwiftUI

@main
struct MinutesApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var setup: ModelSetup
    @State private var library: Library
    @AppStorage("appearance") private var appearance = AppAppearance.system

    init() {
        let setup = ModelSetup()
        _setup = State(initialValue: setup)
        _library = State(initialValue: Library(models: setup.store))
    }

    var body: some Scene {
        Window("Minutes", id: "main") {
            Group {
                if setup.isReady { ContentView() } else { ModelSetupView() }
            }
            .environment(library)
            .environment(setup)
            .frame(minWidth: 860, minHeight: 560)
            .onAppear {
                #if DEBUG
                Debug.start()
                #endif
            }
            // モデルがそろってから、Finder などから渡された音声ファイルを受け付ける
            .onChange(of: setup.isReady, initial: true) { if setup.isReady { delegate.library = library } }
            // 文字起こしのモデルを選び直し、そろったら処理に使うモデルを替える
            .onChange(of: setup.isReady ? setup.whisper : nil) { if setup.isReady { library.useWhisper(setup.store) } }
            .onChange(of: appearance, initial: true) { appearance.apply() }
        }
        .defaultSize(width: 1200, height: 800)
        .defaultLaunchBehavior(.presented)  // 前回ウィンドウを閉じてから終了していても、起動したら開く
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("録音を追加…") { library.isImporting = true }
                    .keyboardShortcut("o")
                    .disabled(!setup.isReady)
            }
            CommandGroup(after: .sidebar) {
                Picker("外観", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                }
            }
            TextSizeCommands()
            MoveCommands()
        }

        Settings {
            SettingsView()
                .environment(setup)
        }
    }
}

/// 外観: システムに合わせる・ライト・ダーク（「表示」メニューと設定から切り替える）
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }

    var label: String {
        switch self {
        case .system: "システムに合わせる"
        case .light: "ライト"
        case .dark: "ダーク"
        }
    }

    func apply() {
        var appearance: NSAppearance? = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        #if DEBUG
        appearance = Debug.appearance ?? appearance
        #endif
        NSApp.appearance = appearance
    }
}

/// 「表示」メニューの文字の大きさ: 今の表示（通常・没入モード）の本文の文字を段階で大きく・小さくする
private struct TextSizeCommands: Commands {
    @AppStorage("transcript.immersive") private var immersive = false
    @AppStorage(TextSize.normalKey) private var normalStep = TextSize.defaultStep
    @AppStorage(TextSize.immersiveKey) private var immersiveStep = TextSize.defaultStep

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            Button("文字を大きく") { step = step + 1 }
                .keyboardShortcut("+")
                .disabled(step >= TextSize.sizes(immersive: immersive).count - 1)
            Button("文字を小さく") { step = step - 1 }
                .keyboardShortcut("-")
                .disabled(step <= 0)
            Button("標準の大きさ") { step = TextSize.defaultStep }
                .keyboardShortcut("0")
                .disabled(step == TextSize.defaultStep)
        }
    }

    /// 今の表示の段階
    private var step: Int {
        get { immersive ? immersiveStep : normalStep }
        nonmutating set {
            let clamped = min(max(newValue, 0), TextSize.sizes(immersive: immersive).count - 1)
            if immersive { immersiveStep = clamped } else { normalStep = clamped }
        }
    }
}

/// 「移動」メニュー: 前後の見出し・注釈へ（前に出ている録音の画面で）
private struct MoveCommands: Commands {
    @FocusedValue(\.transcriptController) private var controller

    var body: some Commands {
        CommandMenu("移動") {
            Button("次の見出し") { controller?.moveHeading(forward: true) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("前の見出し") { controller?.moveHeading(forward: false) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Divider()
            Button("次の注釈") { controller?.moveAnnotation(forward: true) }
                .keyboardShortcut("]", modifiers: .command)
            Button("前の注釈") { controller?.moveAnnotation(forward: false) }
                .keyboardShortcut("[", modifiers: .command)
        }
    }
}

/// Finder の「このアプリケーションで開く」や Dock へのドロップで渡された音声ファイルを録音として追加する
final class AppDelegate: NSObject, NSApplicationDelegate {
    var library: Library? { didSet { flush() } }
    private var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        pending += urls
        flush()
    }

    private func flush() {
        guard let library, !pending.isEmpty else { return }
        if let r = library.add(pending) { library.focus = r.id }
        pending = []
    }
}
