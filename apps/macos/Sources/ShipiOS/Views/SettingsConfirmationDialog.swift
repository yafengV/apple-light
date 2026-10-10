import SwiftUI

/// A centered modal inside the main content, rather than an AppKit sheet/popover.
struct SettingsConfirmationDialog: View {
  let title: String
  let message: String
  let confirmLabel: String
  let busyLabel: String
  let busy: Bool
  let error: String?
  let width: CGFloat
  let identifier: String
  var cancelLabel = "取消"
  let cancel: () -> Void
  let confirm: () -> Void
  @Environment(\.appAppearance) private var appearance
  @FocusState private var focusedButton: Action?
  @State private var keyboardSelection = ModalButtonSelection<Action>(.cancel)
  enum Action { case cancel, confirm }

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color.black.opacity(0.3).contentShape(Rectangle())
          .onTapGesture { if !busy { cancel() } }
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 12) {
          Text(title).font(.system(size: 17, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
          Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          if let error {
            Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
          }
          HStack(spacing: 12) {
            Spacer()
            Button(cancelLabel, action: cancel)
              .buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 8)
              .focusable(!busy).focused($focusedButton, equals: .cancel).focusEffectDisabled()
              .overlay { focusOutline(.cancel) }
            Button { confirm() } label: {
              HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.small) }
                Text(busy ? busyLabel : confirmLabel)
              }.padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(.white)
                .background(Color.red, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain)
              .focusable(!busy).focused($focusedButton, equals: .confirm).focusEffectDisabled()
              .overlay { focusOutline(.confirm) }
          }.disabled(busy)
        }
        .padding(20)
        .frame(width: min(width, geometry.size.width * 0.92), alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier(identifier)
        .onChange(of: focusedButton) { _, value in
          if let value { keyboardSelection.current = value }
        }
        .background(ModalKeyboardBridge(onReady: {
          keyboardSelection.current = .cancel; focusedButton = .cancel
        }) { key in
          guard !busy else { return }
          switch key {
          case .cancel: cancel()
          case .activate:
            if keyboardSelection.current == .confirm { confirm() } else { cancel() }
          case .next: focusedButton = keyboardSelection.advance(between: .cancel, and: .confirm)
          }
        }.frame(width: 0, height: 0))
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
  @ViewBuilder private func focusOutline(_ action: Action) -> some View {
    if focusedButton == action && !busy {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(appearance.accentColor, lineWidth: 2)
        .padding(-3).allowsHitTesting(false)
    }
  }
}
