import SwiftUI

/// 設定: 外観と、ハイライトの色の名前（色の意味。アプリ全体で共通）
struct SettingsView: View {
    @AppStorage("appearance") private var appearance = AppAppearance.system

    var body: some View {
        Form {
            Picker("外観", selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
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
