// 複数の画面で使う部品: アプリのマーク・ボタンのスタイル・ホバーの受け取り
import SwiftUI

/// アプリのマーク（アイコンと同じ、青から藍の M。素材は tools/app-icon.svg から作る）
struct AppMark: View {
    var size: CGFloat

    var body: some View {
        Image("AppMark")
            .resizable()
            .frame(width: size, height: size)
            .shadow(color: Color(red: 0.22, green: 0.19, blue: 0.64).opacity(0.25), radius: size * 0.12, y: size * 0.06)
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
