import SwiftUI

/// Matches the archive page's danger, ghost-danger, and secondary toolbar actions.
struct ArchiveActionButtonStyle: ButtonStyle {
  enum Kind { case deleteAll, deleteSingle, restore }
  let kind: Kind
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovered = false

  func makeBody(configuration: Configuration) -> some View {
    let highlighted = isEnabled && (hovered || configuration.isPressed)
    let color: Color = kind == .restore ? .primary : .red
    let opacity: Double = switch kind {
    case .deleteAll: highlighted ? 0.20 : 0.10
    case .deleteSingle: highlighted ? 0.10 : 0
    case .restore: highlighted ? 0.10 : 0.05
    }
    configuration.label.appFont(size: 13)
      .padding(.horizontal, kind == .deleteSingle ? 0 : 8)
      .frame(minWidth: 28, minHeight: 28)
      .foregroundStyle(color)
      .background(color.opacity(opacity), in: RoundedRectangle(cornerRadius: 8))
      .opacity(isEnabled ? 1 : 0.4)
      .contentShape(RoundedRectangle(cornerRadius: 8))
      .onHover { hovered = $0 }
  }
}

struct ArchiveRestoreLabel: View {
  let busy: Bool
  var body: some View {
    HStack(spacing: 4) {
      if busy { ProgressView().controlSize(.mini).accessibilityHidden(true) }
      Text("恢复")
    }
  }
}
