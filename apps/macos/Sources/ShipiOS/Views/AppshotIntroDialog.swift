import SwiftUI

/// Appshot consent is shown inside the main window, including when a shortcut
/// was pressed while another application was frontmost.
struct AppshotIntroDialog: View {
  let cancel: () -> Void
  let enable: () -> Void
  @Environment(\.appAppearance) private var appearance
  @FocusState private var focusedButton: Action?
  private enum Action { case cancel, enable }

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color.black.opacity(0.3).contentShape(Rectangle())
          .onTapGesture(perform: cancel)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 18) {
          Image(systemName: "macwindow.on.rectangle")
            .font(.system(size: 48, weight: .light))
            .foregroundStyle(appearance.accentColor)
            .frame(width: 88, height: 77, alignment: .leading)
            .accessibilityHidden(true)
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
        .background(ModalKeyboardBridge(onReady: { focusedButton = .cancel }) { key in
          switch key {
          case .cancel: cancel()
          case .activate: focusedButton == .enable ? enable() : cancel()
          case .next: focusedButton = focusedButton == .cancel ? .enable : .cancel
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
