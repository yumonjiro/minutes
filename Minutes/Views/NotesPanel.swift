import MinutesCore
import SwiftUI

/// 右のパネル: 「目次」（見出しの木。今いる見出しを強調）と「注釈」（ハイライト・ブックマークの一覧。色・種類で絞り込み、検索）。
/// クリックでその所へ移る（再生位置も移す）。目次は右の再生ボタンで、注釈はダブルクリックで、そこから再生する
struct NotesPanel: View {
    enum Tab: String {
        case outline, notes
    }

    let model: TranscriptModel
    let recording: Recording
    let player: AudioPlayer
    let controller: TranscriptController
    @AppStorage("notesPanel.tab") private var tab = Tab.outline

    var body: some View {
        let notes = model.resolve(recording.notes)
        VStack(spacing: 0) {
            Picker("表示", selection: $tab) {
                Text("目次").tag(Tab.outline)
                Text("注釈").tag(Tab.notes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            switch tab {
            case .outline: OutlineList(model: model, recording: recording, player: player, controller: controller, headings: notes.headings)
            case .notes: AnnotationList(model: model, recording: recording, controller: controller, notes: notes)
            }
        }
    }
}

// MARK: - 目次

private struct OutlineList: View {
    let model: TranscriptModel
    let recording: Recording
    let player: AudioPlayer
    let controller: TranscriptController
    let headings: [ResolvedNotes.Heading]
    @State private var renaming: UUID?
    @State private var newTitle = ""

    var body: some View {
        if headings.isEmpty {
            EmptyNote(icon: "list.bullet.indent", title: "見出しはまだありません",
                      detail: "文字起こしの発言と発言の間を押すか、話題を表す言葉を選んで「見出し」を押して入れます")
        } else {
            let current = player.shownBlock.flatMap { b in headings.last { $0.block <= b }?.id }
            List {
                ForEach(Array(headings.enumerated()), id: \.element.id) { i, h in
                    row(h, next: i + 1 < headings.count ? headings[i + 1] : nil, current: h.id == current)
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func row(_ h: ResolvedNotes.Heading, next: ResolvedNotes.Heading?, current: Bool) -> some View {
        let start = model.blocks[h.block].start
        let end = next.map { model.blocks[$0.block].start } ?? model.duration
        return HStack(spacing: 8) {
            if renaming == h.id {
                TextField("見出しの名前", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        recording.updateAnnotation(h.id) { $0.text = title }
                        renaming = nil
                    }
                    .onExitCommand { renaming = nil }
            } else {
                Text(h.title.isEmpty ? "無題の見出し" : h.title)
                    .font(.system(size: h.level == 1 ? 13 : 12, weight: h.level == 1 ? .semibold : .regular))
                    .foregroundStyle(h.title.isEmpty ? AnyShapeStyle(.tertiary) : h.level == 1 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                Spacer(minLength: 4)
                Text("\(formatTime(start))・\(formatDuration(max(0, end - start)))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                Button { controller.jump(toBlock: h.block, play: true) } label: {
                    Image(systemName: "play.fill").font(.system(size: 9))
                }
                .buttonStyle(RowPlayButtonStyle())
                .help("ここから再生")
            }
        }
        .padding(.leading, h.level == 2 ? 14 : 0)
        .padding(.vertical, 3)
        .listRowBackground(current ? RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.14)).padding(.horizontal, 8) : nil)
        .contentShape(Rectangle())
        .onTapGesture { controller.jump(toBlock: h.block) }
        .help("クリックでその所へ（再生は右のボタン）")
        .contextMenu {
            Button("名前を変える…") {
                newTitle = h.title
                renaming = h.id
            }
            Button(h.level == 1 ? "小見出しにする" : "議題にする") { recording.updateAnnotation(h.id) { $0.level = h.level == 1 ? 2 : 1 } }
            Divider()
            Button("見出しを削除", role: .destructive) { recording.removeAnnotation(h.id) }
        }
    }
}

// MARK: - 注釈

private struct AnnotationList: View {
    let model: TranscriptModel
    let recording: Recording
    let controller: TranscriptController
    let notes: ResolvedNotes
    /// 絞り込み: 表示する色（空ならすべて）、ブックマークを含めるか、コメントのあるものだけか、検索する語
    @State private var colors: Set<Int> = []
    @State private var bookmarks = true
    @State private var commented = false
    @State private var query = ""
    @State private var editing: UUID?

    /// 一覧の 1 行: ハイライトかブックマーク
    private struct Item: Identifiable {
        var id: UUID
        var time: Double
        var block: Int
        var highlight: ResolvedNotes.Highlight?
        var text: String
    }

    var body: some View {
        let items = filtered
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(0..<HighlightColor.count, id: \.self) { i in
                        FilterDot(index: i, on: colors.isEmpty || colors.contains(i)) { toggle(i) }
                    }
                    Spacer()
                    Toggle(isOn: $bookmarks) { Image(systemName: "bookmark.fill") }
                        .toggleStyle(.button)
                        .help("ブックマークも表示")
                    Toggle(isOn: $commented) { Image(systemName: "text.bubble") }
                        .toggleStyle(.button)
                        .help("コメントのあるものだけ")
                }
                .controlSize(.small)
                TextField("注釈を検索", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if notes.highlights.isEmpty && notes.bookmarks.isEmpty {
                EmptyNote(icon: "highlighter", title: "注釈はまだありません",
                          detail: "文字起こしで文字を選んで色を押すとハイライト、発言の左の余白のしおりか B キーでブックマーク")
            } else if items.isEmpty {
                EmptyNote(icon: "line.3.horizontal.decrease", title: "条件に合う注釈はありません", detail: "")
            } else {
                List(items) { item in row(item) }
                    .listStyle(.sidebar)
            }
        }
    }

    private var filtered: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var items: [Item] = notes.highlights.compactMap { h in
            guard colors.isEmpty || colors.contains(h.color), !commented || !h.comment.isEmpty else { return nil }
            let w = model.words[h.words.lowerBound]
            return Item(id: h.id, time: w.start, block: w.block, highlight: h, text: model.words[h.words].map(\.text).joined())
        }
        if bookmarks && !commented {
            items += notes.bookmarks.map { b, id in Item(id: id, time: model.blocks[b].start, block: b, text: model.text(of: model.blocks[b])) }
        }
        if !q.isEmpty {
            items = items.filter { item in
                [item.text, item.highlight?.comment ?? "", recording.name(of: model.blocks[item.block].speaker)].contains { $0.lowercased().contains(q) }
            }
        }
        return items.sorted { $0.time < $1.time }
    }

    private func toggle(_ i: Int) {
        if colors.isEmpty { colors = Set(0..<HighlightColor.count).subtracting([i]) } else if colors.contains(i) { colors.remove(i) } else { colors.insert(i) }
        if colors.count == HighlightColor.count { colors = [] }
    }

    private func row(_ item: Item) -> some View {
        let speaker = recording.name(of: model.blocks[item.block].speaker)
        let jump = { (play: Bool) in
            if let h = item.highlight { controller.jump(toWord: h.words.lowerBound, play: play) } else { controller.jump(toBlock: item.block, play: play) }
        }
        return HStack(alignment: .top, spacing: 8) {
            if let h = item.highlight {
                RoundedRectangle(cornerRadius: 1.5).fill(Color(nsColor: HighlightColor.solid[h.color])).frame(width: 3)
            } else {
                Image(systemName: "bookmark.fill").font(.system(size: 10)).foregroundStyle(Color.accentColor).frame(width: 10).padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text).font(.system(size: 12.5)).lineLimit(3)
                if let comment = item.highlight?.comment, !comment.isEmpty {
                    Label(comment, systemImage: "text.bubble")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                Text([speaker, formatTime(item.time), item.highlight.map { HighlightColor.name($0.color) }].compactMap { $0 }.joined(separator: "・"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { jump(true) }
        .simultaneousGesture(TapGesture().onEnded { jump(false) })
        .help("クリックでその所へ、ダブルクリックでそこから再生")
        .popover(isPresented: Binding(get: { editing == item.id }, set: { if !$0 { editing = nil } }), arrowEdge: .leading) {
            if let h = item.highlight {
                CommentPopover(text: h.comment, color: h.color, isNew: false, save: { text, color in
                    recording.updateAnnotation(h.id) {
                        $0.text = text
                        $0.color = color
                    }
                }, delete: { recording.removeAnnotation(h.id) }, close: { editing = nil })
            }
        }
        .contextMenu {
            if let h = item.highlight {
                Button(h.comment.isEmpty ? "コメントを付ける…" : "コメントを編集…") { editing = item.id }
                Menu("色") {
                    ForEach(0..<HighlightColor.count, id: \.self) { i in
                        Button(HighlightColor.name(i)) { recording.updateAnnotation(h.id) { $0.color = i } }
                    }
                }
                Divider()
                Button("ハイライトを削除", role: .destructive) { recording.removeAnnotation(h.id) }
            } else {
                Button("ブックマークを外す", role: .destructive) { recording.removeAnnotation(item.id) }
            }
        }
    }
}

/// 目次の行の右の再生ボタン（丸。ポインタが乗ると色が付く）
private struct RowPlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hoverable { hover in
            configuration.label
                .foregroundStyle(hover ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 20, height: 20)
                .background(Circle().fill(hover || configuration.isPressed ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)))
                .contentShape(Circle())
        }
    }
}

/// 絞り込みの色の丸（表示しない色は薄く）
private struct FilterDot: View {
    let index: Int
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(nsColor: HighlightColor.solid[index]).opacity(on ? 1 : 0.2))
                .frame(width: 12, height: 12)
                .frame(width: 20, height: 20)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("\(HighlightColor.name(index))（押すと表示・非表示）")
    }
}

/// 一覧が空のときの説明
private struct EmptyNote: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(.tertiary)
            Text(title).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
