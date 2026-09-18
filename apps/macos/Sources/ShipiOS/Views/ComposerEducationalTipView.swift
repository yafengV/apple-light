import SwiftUI

struct ComposerEducationalTipView: View {
  let tip: ComposerEducationalTip
  let action: () -> Void
  let dismiss: () -> Void
  @State private var hovering = false
  @FocusState private var dismissFocused: Bool

  var body: some View {
    HStack(spacing: 8) {
      Text("提示")
        .appFont(size: 9, weight: .bold)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .foregroundStyle(.secondary)
        .background(.primary.opacity(0.07), in: Capsule())
      Text(tip.content)
        .lineLimit(2).multilineTextAlignment(.center)
      Button(action: action) {
        Text(tip.actionLabel).underline(true, pattern: .dot)
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .accessibilityLabel(tip.actionLabel)
      Button(action: dismiss) {
        Image(systemName: "xmark")
          .frame(width: 20, height: 20)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .focused($dismissFocused)
      .opacity(hovering || dismissFocused ? 1 : 0)
      .accessibilityLabel("关闭提示")
      .help("永久关闭此提示")
    }
    .appFont(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 7).padding(.vertical, 2)
    .frame(maxWidth: .infinity, alignment: .center)
    .onHover { hovering = $0 }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("教育提示：\(tip.content)")
  }
}
