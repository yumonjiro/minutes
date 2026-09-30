import SwiftUI

/// ウィンドウ全体: 左に録音の一覧、右に選んだ録音。どこに音声ファイルをドロップしても追加できる
struct ContentView: View {
    @Environment(Library.self) private var library
    @State private var selection: String?
    @State private var dropping = false

    var body: some View {
        @Bindable var library = library
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            if let id = selection, let r = library.recording(id) {
                RecordingView(recording: r).id(id)
            } else {
                WelcomeView()
            }
        }
        .fileImporter(isPresented: $library.isImporting, allowedContentTypes: Library.audioTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { add(urls) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        } isTargeted: { dropping = $0 }
        .overlay {
            if dropping {
                DropOverlay().transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: dropping)
        .onAppear {
            if selection == nil { selection = library.recordings.first?.id }
            #if DEBUG
            if let id = Debug.env["MINUTES_OPEN"] { selection = id }
            #endif
        }
        .onChange(of: library.focus) {
            if let id = library.focus { selection = id }
            library.focus = nil
        }
        .onChange(of: library.recordings.map(\.id)) { _, ids in
            if let id = selection, !ids.contains(id) { selection = ids.first }
        }
    }

    private func add(_ urls: [URL]) {
        if let r = library.add(urls) { selection = r.id }
    }
}

private struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 20)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 30))
                    Text("ドロップして録音を追加").font(.headline)
                }
                .foregroundStyle(Color.accentColor)
            }
            .padding(14)
            .allowsHitTesting(false)
    }
}

/// 録音がまだ無いとき・選んでいないときの画面
struct WelcomeView: View {
    @Environment(Library.self) private var library

    var body: some View {
        VStack(spacing: 0) {
            AppMark(size: 64)
                .padding(.bottom, 22)
            Text("会議の録音を、読める文字起こしに")
                .font(.system(size: 26, weight: .bold))
                .padding(.bottom, 10)
            Text("音声ファイルを追加すると、話者を聞き分けて、発言ごとに文字起こしします。\n処理はすべてこの Mac の中で行われ、外部には送信されません。")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(5)
                .padding(.bottom, 26)
            Button("音声ファイルを選ぶ") { library.isImporting = true }
                .buttonStyle(PillButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
            Text("ここにドロップしても追加できます（m4a・mp3・wav・mp4 など）")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 16)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("")
    }
}
