import ModelStore
import SwiftUI

/// 設定: 外観、文字起こしのモデル、ハイライトの色の名前（色の意味。アプリ全体で共通）
struct SettingsView: View {
    @Environment(ModelSetup.self) private var setup
    @AppStorage("appearance") private var appearance = AppAppearance.system

    var body: some View {
        @Bindable var setup = setup
        Form {
            Picker("外観", selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Section {
                Picker("文字起こしのモデル", selection: $setup.whisper) {
                    Text("速さ優先（large-v3-turbo）").tag(ModelStore.Whisper.turbo)
                    Text("精度優先（large-v3）").tag(ModelStore.Whisper.large)
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("精度優先は約 3 倍の時間がかかり、メモリも多く使う。まだ取得していないモデルを選ぶと、ダウンロードの画面になる（turbo 約 1.6GB、large-v3 約 3.1GB）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("ハイライトの色の名前") {
                ForEach(0..<HighlightColor.count, id: \.self) { i in HighlightNameField(index: i) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// ハイライトの色 1 つの名前の欄（空なら既定の名前）
private struct HighlightNameField: View {
    let index: Int
    @AppStorage private var name: String

    init(index: Int) {
        self.index = index
        _name = AppStorage(wrappedValue: "", HighlightColor.nameKey(index))
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color(nsColor: HighlightColor.solid[index])).frame(width: 12, height: 12)
            TextField("色の名前", text: $name, prompt: Text(HighlightColor.defaultNames[index]))
                .labelsHidden()
        }
    }
}
