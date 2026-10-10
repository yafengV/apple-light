import SwiftUI

/// Appshot consent is shown inside the main window, including when a shortcut
/// was pressed while another application was frontmost.
struct AppshotIntroDialog: View {
  let cancel: () -> Void
  let enable: () -> Void
  @Environment(\.appAppearance) private var appearance
  @FocusState private var focusedButton: Action?
  @State private var keyboardSelection = ModalButtonSelection<Action>(.cancel)
  private enum Action { case cancel, enable }

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color.black.opacity(0.3).contentShape(Rectangle())
          .onTapGesture(perform: cancel)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 18) {
          AppshotIntroArtwork().accessibilityHidden(true)
          Text("启用智能快照")
            .appFont(size: 20, weight: .semibold)
            .accessibilityAddTraits(.isHeader)
          Text("Appshots 可让你将当前窗口附加到消息中。它们会包含窗口中的所有文本，包括已滚出视野的内容。")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          HStack(spacing: 12) {
            Spacer()
            Button("取消", action: cancel)
              .buttonStyle(.plain)
              .padding(.horizontal, 12).padding(.vertical, 8)
              .focusable().focused($focusedButton, equals: .cancel).focusEffectDisabled()
              .overlay { focusOutline(.cancel) }
            Button("启用", action: enable)
              .buttonStyle(.plain)
              .padding(.horizontal, 16).padding(.vertical, 8)
              .foregroundStyle(.white)
              .background(appearance.accentColor, in: RoundedRectangle(cornerRadius: 8))
              .focusable().focused($focusedButton, equals: .enable).focusEffectDisabled()
              .overlay { focusOutline(.enable) }
          }
        }
        .padding(24)
        .frame(width: min(440, geometry.size.width * 0.92), alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("appshot-intro-dialog")
        .onChange(of: focusedButton) { _, value in
          if let value { keyboardSelection.current = value }
        }
        .background(ModalKeyboardBridge(onReady: {
          keyboardSelection.current = .cancel; focusedButton = .cancel
        }) { key in
          switch key {
          case .cancel: cancel()
          case .activate: keyboardSelection.current == .enable ? enable() : cancel()
          case .next: focusedButton = keyboardSelection.advance(between: .cancel, and: .enable)
          }
        }.frame(width: 0, height: 0))
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder private func focusOutline(_ action: Action) -> some View {
    if focusedButton == action {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(appearance.accentColor, lineWidth: 2)
        .padding(-3).allowsHitTesting(false)
    }
  }
}

/// A native ShipiOS illustration that keeps the reference dialog's compact
/// window-and-corners silhouette without bundling the reference artwork.
struct AppshotIntroArtwork: View {
  var width: CGFloat = 88
  private let blue = Color(red: 0.02, green: 0.47, blue: 0.98)

  var body: some View {
    ZStack {
      corners
        .stroke(blue, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
        .shadow(color: .cyan.opacity(0.48), radius: 5)
      RoundedRectangle(cornerRadius: 11, style: .continuous)
        .fill(.white)
        .frame(width: 57, height: 50)
        .shadow(color: .black.opacity(0.16), radius: 4, y: 2)
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 4) {
          Circle().fill(.red).frame(width: 7, height: 7)
          Circle().fill(.yellow).frame(width: 7, height: 7)
          Circle().fill(.green).frame(width: 7, height: 7)
        }
        Text("ShipiOS")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(Color(red: 0.04, green: 0.17, blue: 0.43))
        Text("窗口快照")
          .font(.system(size: 7, weight: .medium))
          .foregroundStyle(Color(red: 0.29, green: 0.45, blue: 0.70))
      }
      .frame(width: 45, alignment: .leading)
    }
    .frame(width: 88, height: 77)
    .scaleEffect(width / 88, anchor: .topLeading)
    .frame(width: width, height: 77 * width / 88, alignment: .topLeading)
  }

  private var corners: Path {
    Path { path in
      path.move(to: CGPoint(x: 37, y: 7))
      path.addLine(to: CGPoint(x: 26, y: 7))
      path.addQuadCurve(to: CGPoint(x: 8, y: 25), control: CGPoint(x: 8, y: 7))
      path.addLine(to: CGPoint(x: 8, y: 33))

      path.move(to: CGPoint(x: 51, y: 7))
      path.addLine(to: CGPoint(x: 62, y: 7))
      path.addQuadCurve(to: CGPoint(x: 80, y: 25), control: CGPoint(x: 80, y: 7))
      path.addLine(to: CGPoint(x: 80, y: 33))

      path.move(to: CGPoint(x: 8, y: 44))
      path.addLine(to: CGPoint(x: 8, y: 52))
      path.addQuadCurve(to: CGPoint(x: 26, y: 70), control: CGPoint(x: 8, y: 70))
      path.addLine(to: CGPoint(x: 37, y: 70))

      path.move(to: CGPoint(x: 80, y: 44))
      path.addLine(to: CGPoint(x: 80, y: 52))
      path.addQuadCurve(to: CGPoint(x: 62, y: 70), control: CGPoint(x: 80, y: 70))
      path.addLine(to: CGPoint(x: 51, y: 70))
    }
  }
}
