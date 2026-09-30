// 文字起こしの上に出す小さな UI: 文字を選んだときのバーと、コメント・見出し・話者名の小窓
import AppKit
import SwiftUI

/// 選択のすぐ上に出すバー: ハイライトの 5 色・コメント・見出し・コピー・選択の解除
struct SelectionToolbar: View {
    enum Action {
        case highlight(Int), comment, heading, copy, clear
    }

    /// 選んでいる語（変わったら「コピーしました」を戻す）
    let key: ClosedRange<Int>
    let run: (Action) -> Void
    @State private var copied = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<HighlightColor.count, id: \.self) { i in
                ColorDot(index: i) { run(.highlight(i)) }
            }
            Divider().frame(height: 18).padding(.horizontal, 4)
            Button("コメント", systemImage: "text.bubble") { run(.comment) }
                .help("コメントを付ける")
            Button("見出し", systemImage: "number") { run(.heading) }
                .help("この文の前に見出しを入れる（選んだ言葉が名前になる。発言の途中なら、そこで発言を分ける）")
            Button(copied ? "コピーしました" : "コピー", systemImage: copied ? "checkmark" : "doc.on.doc") {
                run(.copy)
                copied = true
            }
            .help("選んだ所をコピー（⌘C）")
            Button("選択を解除", systemImage: "xmark") { run(.clear) }
                .labelStyle(.iconOnly)
                .help("選択を解除（esc）")
        }
        .buttonStyle(BarButtonStyle())
        .font(.system(size: 12, weight: .medium))
        .padding(4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(color: .black.opacity(0.14), radius: 8, y: 2)
        .fixedSize()
        .onChange(of: key) { copied = false }
    }
}

/// ハイライトの色の丸（ポインタが乗ると輪）
private struct ColorDot: View {
    let index: Int
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Hoverable { hover in
                Circle()
                    .fill(Color(nsColor: HighlightColor.solid[index]))
                    .frame(width: 14, height: 14)
                    .padding(3)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(hover || selected ? 0.5 : 0), lineWidth: 1.5))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .help("ハイライト: \(HighlightColor.name(index))")
    }
}

/// ハイライトのコメントと色。新しいときは閉じたときにコメントがあれば付け、今あるものは閉じたときに変更を保存する
struct CommentPopover: View {
    @State var text: String
    @State var color: Int
    let isNew: Bool
    let save: (String, Int) -> Void
    let delete: (() -> Void)?
    let close: () -> Void
    @State private var deleted = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                Text(isNew ? "コメント" : "ハイライト").font(.caption).foregroundStyle(.secondary)
                Spacer()
                ForEach(0..<HighlightColor.count, id: \.self) { i in
                    ColorDot(index: i, selected: color == i) { color = i }
                }
            }
            TextField("コメント（⌥↩︎ で改行）", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...10)
                .focused($focused)
                .onSubmit(close)
            HStack {
                if let delete {
                    Button("ハイライトを削除", role: .destructive) {
                        deleted = true
                        delete()
                        close()
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                Button("完了", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 330)
        .onAppear { focused = true }
        .onDisappear {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !deleted, !isNew || !text.isEmpty { save(text, color) }
        }
    }
}

/// 見出し（議題・小見出し）の名前と段。閉じたときに保存する（新しい見出しは名前があるときだけ）
struct HeadingPopover: View {
    @State var title: String
    @State var level: Int
    let isNew: Bool
    let save: (String, Int) -> Void
    let delete: (() -> Void)?
    let close: () -> Void
    @State private var deleted = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("見出しの段", selection: $level) {
                Text("議題").tag(1)
                Text("小見出し").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField("見出しの名前（例: 来期の予算）", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(close)
            HStack {
                if let delete {
                    Button("見出しを削除", role: .destructive) {
                        deleted = true
                        delete()
                        close()
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                Button(isNew ? "追加" : "完了", action: close)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isNew && trimmed.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { focused = true }
        // 新しい見出しは、名前を入れずに閉じたら入れない（発言の間を押しただけのとき）
        .onDisappear { if !deleted, !(isNew && trimmed.isEmpty) { save(trimmed, level) } }
    }

    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// 話者名のクリックで出す、名前の変更と絞り込み
struct SpeakerPopover: View {
    @State var name: String
    let filtered: Bool
    let rename: (String) -> Void
    let filter: (Bool) -> Void
    let close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("話者の名前").font(.caption).foregroundStyle(.secondary)
            TextField("名前", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { rename(name); close() }
            Button(filtered ? "すべての話者を表示" : "この話者だけを表示",
                   systemImage: filtered ? "eye" : "eye.slash") { filter(!filtered); close() }
                .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 240)
        .onAppear { focused = true }
    }
}

/// 選択のバーのボタン（ポインタが乗ると薄い背景）
struct BarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hoverable { hover in
            configuration.label
                .foregroundStyle(hover ? .primary : .secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(hover || configuration.isPressed ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: Capsule())
                .contentShape(Capsule())
        }
    }
}

/// 画面の上に浮かぶ小さなボタン（「再生位置に戻る」。ポインタが乗ると少し濃く）
struct FloatingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hoverable { hover in
            configuration.label
                .font(.system(size: 12.5, weight: .medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().fill(Color.primary.opacity(hover ? 0.06 : 0)))
                .overlay(Capsule().strokeBorder(.separator))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                .opacity(configuration.isPressed ? 0.8 : 1)
                .contentShape(Capsule())
        }
    }
}
