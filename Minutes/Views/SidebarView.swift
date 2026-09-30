import SwiftUI

/// 左の一覧: 録音の追加・録音（処理中は進み具合）
struct SidebarView: View {
    @Environment(Library.self) private var library
    @Binding var selection: String?
    @State private var renaming: Recording?
    @State private var newTitle = ""
    @State private var deleting: Recording?

    var body: some View {
        List(selection: $selection) {
            Section("録音") {
                ForEach(library.recordings) { r in
                    RecordingRow(recording: r, selected: selection == r.id)
                        .tag(r.id)
                        .contextMenu {
                            Button("名前を変更…") {
                                newTitle = r.title
                                renaming = r
                            }
                            Divider()
                            Button("削除…", role: .destructive) { deleting = r }
                        }
                }
                if library.recordings.isEmpty {
                    Text("まだ録音がありません").foregroundStyle(.tertiary)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 9) {
                    AppMark(size: 22)
                    Text("Minutes").font(.system(size: 16, weight: .semibold))
                }
                .padding(.leading, 6)
                Button { library.isImporting = true } label: {
                    Label("録音を追加", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(AddButtonStyle())
                .help("音声ファイルを追加（⌘O）")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        .alert("録音の名前を変更", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名前", text: $newTitle)
            Button("キャンセル", role: .cancel) {}
            Button("変更") {
                let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if let r = renaming, !title.isEmpty { r.meta.title = title }
            }
        }
        .confirmationDialog("「\(deleting?.title ?? "")」を削除しますか？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("削除", role: .destructive) { if let r = deleting { library.delete(r) } }
        } message: {
            Text("音声と文字起こしが削除され、元に戻せません。")
        }
    }
}

/// 録音の行。ポインタが乗ると（選んでいなければ）薄い背景を付ける
private struct RecordingRow: View {
    let recording: Recording
    let selected: Bool
    @State private var hover = false
    #if DEBUG
    @Environment(Library.self) private var library
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(recording.title).lineLimit(1)
            HStack(spacing: 5) {
                if let stage = recording.stage {
                    if stage.isActive {
                        if stage == .queued { Image(systemName: "clock") } else { ProgressView().controlSize(.mini) }
                    } else {
                        Image(systemName: "exclamationmark.circle")
                    }
                    Text(stage.shortText)
                } else {
                    Text(formatDate(recording.meta.created) + (recording.meta.duration.map { " · " + formatDuration($0) } ?? ""))
                }
            }
            .font(.caption)
            .foregroundStyle(recording.stage?.isActive == false ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .lineLimit(1)
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background {
            if hover && !selected {
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)).padding(.horizontal, -6).padding(.vertical, -2)
            }
        }
        .onHover { hover = $0 }
        #if DEBUG
        .onAppear { if Debug.sidebarHover == library.recordings.firstIndex(where: { $0 === recording }) { hover = true } }
        #endif
    }
}

extension Recording.Stage {
    var shortText: String {
        switch self {
        case .queued: "順番待ち"
        case .decoding: "音声を読み込み中…"
        case .diarizing: "話者分離中…"
        case .loadingWhisper: "準備中…"
        case .transcribing: "文字起こし中…"
        case .failed: "処理に失敗しました"
        case .interrupted: "処理が中断されました"
        }
    }
}

/// 「録音を追加」: Gemini の「新しいチャット」のような丸いボタン
private struct AddButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hoverable { hover in
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(Color(nsColor: .controlBackgroundColor).opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
                .overlay(Capsule().strokeBorder(.separator))
                .shadow(color: .black.opacity(hover ? 0.1 : 0), radius: 6, y: 2)
                .contentShape(Capsule())
        }
    }
}
