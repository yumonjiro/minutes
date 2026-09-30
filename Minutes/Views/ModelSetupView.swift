import SwiftUI

/// 初回の画面: 文字起こしなどに使うモデルを Hugging Face から取得する（そろうまではこの画面だけを出す）
struct ModelSetupView: View {
    @Environment(ModelSetup.self) private var setup

    var body: some View {
        VStack(spacing: 0) {
            AppMark(size: 64)
                .padding(.bottom, 22)
            Text("モデルをダウンロードします")
                .font(.system(size: 26, weight: .bold))
                .padding(.bottom, 10)
            Text("話者の聞き分け・文字起こし・発言の整形に使うモデルのうち、まだ無いものを Hugging Face から取得します。\n録音の処理はすべてこの Mac の中で行われ、録音が外部に送信されることはありません。")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(5)
                .padding(.bottom, 26)
            switch setup.state {
            case .ready:
                EmptyView()
            case .needed(let bytes):
                Button("ダウンロード") { setup.start() }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                Text(bytes.map { "約 \($0.formatted(.byteCount(style: .file)))・空き容量も同じくらい必要です" } ?? " ")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 16)
            case .downloading(let fraction):
                ProgressView(value: fraction)
                    .frame(width: 320)
                Text("ダウンロード中… \(fraction.formatted(.percent.precision(.fractionLength(0))))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.top, 10)
                Button("中止") { setup.cancel() }
                    .buttonStyle(PillButtonStyle())
                    .padding(.top, 18)
            case .failed(let message):
                Text("ダウンロードできませんでした")
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                    .padding(.bottom, 18)
                Button("もう一度試す") { setup.start() }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
