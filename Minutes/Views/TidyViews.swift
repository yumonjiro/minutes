import SwiftUI

/// 整形した表示（整形・見比べ）で、まだ整形していないときの説明と「整形する」ボタン
struct TidyIntro: View {
    /// 文字起こしの処理中（終わるまで整形できない）
    let processing: Bool
    let start: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text("発言を整形して読みやすくします")
                .font(.system(size: 16, weight: .semibold))
            Text("「えー」「あの」などのつなぎ言葉や言い直し、相槌だけの発言を取り除きます。\n言葉の中身は変えません。整形はこの Mac の中で行います。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            Button("整形する", action: start)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)
                .disabled(processing)
            if processing {
                Text("文字起こしが終わると整形できます")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 整形した表示の上の細い帯: 整形の進み具合と止める・続ける、終わったら何を取り除いたか
struct TidyBar: View {
    let recording: Recording
    let tidy: TidyService
    /// 文字起こしの列の幅（帯の中身をそろえる）
    let width: CGFloat

    var body: some View {
        let (done, total) = recording.tidyProgress
        HStack(spacing: 10) {
            switch recording.tidyState {
            case .running:
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .frame(width: 120)
                Text("整形中 \(done) / \(total) 発言")
                    .monospacedDigit()
                Button("止める") { tidy.stop(recording) }
            case .waiting(let reason):
                ProgressView().controlSize(.small)
                Text(reason)
                Button("止める") { tidy.stop(recording) }
            case .stopped:
                Image(systemName: "pause.circle")
                Text("整形を止めました（\(done) / \(total) 発言）")
                    .monospacedDigit()
                Button("続ける") { tidy.start(recording) }
            case .failed(let message):
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.red)
                Text("整形できませんでした: \(message)")
                    .lineLimit(1)
                Button("もう一度") { tidy.start(recording) }
            case nil:
                if let t = recording.tidiedTranscript {
                    Image(systemName: "checkmark.circle")
                    Text("相槌など \(t.droppedCount) 発言を省き、つなぎ言葉など \(t.removedCount) か所を取り除きました")
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .controlSize(.small)
        .frame(maxWidth: width)
        .padding(.horizontal, 32)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) { Divider() }
    }
}
