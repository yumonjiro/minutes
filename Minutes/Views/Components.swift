// 複数の画面で使う部品: アプリのマーク・ボタンのスタイル・ホバーの受け取り
import SwiftUI

/// アプリのマーク（角丸の四角に波形）
struct AppMark: View {
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.31, green: 0.49, blue: 1), Color(red: 0.61, green: 0.36, blue: 0.9)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "waveform").font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white)
            }
            .shadow(color: Color(red: 0.31, green: 0.49, blue: 1).opacity(0.3), radius: size * 0.2, y: size * 0.08)
    }
}

/// 丸い（錠剤形の）ボタン。prominent は塗りつぶし（主な操作）
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .padding(.horizontal, 20)
            .frame(height: 38)
            .foregroundStyle(prominent ? Color(nsColor: .windowBackgroundColor) : .primary)
            .background(prominent ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary), in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : isEnabled ? 1 : 0.35)
            .contentShape(Capsule())
    }
}

/// 背景なしのアイコンボタン（ホバーで薄い背景）
struct IconButtonStyle: ButtonStyle {
    var width: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        Hoverable { hover in
            configuration.label
                .font(.system(size: 15))
                .foregroundStyle(hover ? .primary : .secondary)
                .frame(minWidth: width, minHeight: 30)
                .background(hover || configuration.isPressed ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .modifier(DimWhenDisabled())
    }
}

/// マウスが乗っているかを中身に渡す
struct Hoverable<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @State private var hover = false

    var body: some View {
        content(hover).onHover { hover = $0 }
    }
}

/// 使えない（disabled）ときは薄くする
struct DimWhenDisabled: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.opacity(isEnabled ? 1 : 0.35)
    }
}
