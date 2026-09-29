import AppKit
import SwiftUI

struct WorkspaceNoticeCard: View {
  let store: WorkspaceStore
  let notice: WorkspaceNotice
  @FocusState.Binding var focused: String?
  @Environment(\.appAppearance) private var appearance
  @Environment(\.colorScheme) private var scheme
  @State private var closeHovered = false
  @State private var actionHovered = false
  private var resolved: AppearancePreferences {
    var value = appearance
    if value.theme == "system" { value.theme = scheme == .dark ? "dark" : "light" }
    return value
  }
  private var colors: NoticeCardColors { .init(level: notice.level, appearance: resolved) }

  var body: some View {
    NoticeIntrinsicWidth {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .top, spacing: 4) {
          Group {
            if notice.level == .pending { ProgressView().controlSize(.small) }
            else { NoticeGlyph(level: notice.level).frame(width: 16, height: 16) }
          }.frame(width: 24, height: 24).accessibilityHidden(true)
          HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
              lineBox(notice.title, weight: .medium).frame(minHeight: 24)
              if let description = notice.description, !description.isEmpty {
                lineBox(NoticeTextLayout.description(description)).foregroundStyle(descriptionColor)
              }
            }
            if notice.description == nil, notice.taskID != nil { action }
          }
          if notice.level != .pending {
            Button { store.notices.dismiss(notice.id, generation: notice.generation) } label: {
              NoticeGlyph(close: true).frame(width: 16, height: 16)
                .frame(width: 24, height: 24)
                .background(closeHovered ? closeHoverColor : .clear, in: Circle())
                .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("关闭")
              .focused($focused, equals: notice.generation.uuidString + "-close")
              .onHover { closeHovered = $0 }
          }
        }
        if notice.description != nil, notice.taskID != nil {
          HStack { Spacer(minLength: 0); action }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(9)
      .foregroundStyle(colors.foreground.color)
      .background(colors.background.color, in: RoundedRectangle(cornerRadius: 15))
      .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(colors.border.color, lineWidth: 1))
      .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
    }
    .accessibilityIdentifier("workspace-notice:" + notice.id)
    .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
      if value.translation.width > 60 && abs(value.translation.height) < value.translation.width {
        store.notices.dismiss(notice.id, generation: notice.generation)
      }
    })
  }

  private var descriptionColor: Color {
    if notice.level == .info || notice.level == .pending { return resolved.resolvedColors["textForegroundSecondary"].color }
    var foreground = colors.foreground; foreground.alpha *= 0.8; return foreground.color
  }
  private var closeHoverColor: Color {
    var color = resolved.resolvedColors["buttonSecondaryBackgroundHover"]; color.alpha *= 0.05; return color.color
  }
  private func lineBox(_ value: String, weight: Font.Weight = .regular) -> some View {
    let font = resolved.nativeFont(size: 14)
    let extra = max(0, font.pointSize * 1.5 - NSLayoutManager().defaultLineHeight(for: font))
    return Text(value).font(resolved.font(size: 14, weight: weight)).lineSpacing(extra)
      .padding(.vertical, extra / 2).fixedSize(horizontal: false, vertical: true)
      .multilineTextAlignment(.leading)
  }
  private var action: some View {
    Button("查看") { Task { await store.openNoticeTask(notice) } }
      .buttonStyle(NoticeActionStyle(appearance: resolved, hovered: actionHovered,
        focused: focused == notice.generation.uuidString + "-view"))
      .focused($focused, equals: notice.generation.uuidString + "-view")
      .onHover { actionHovered = $0 }
      .disabled((store.hasSettingsConfirmation && store.appearanceThemeImport == nil) || store.presentedOverlay != nil)
  }
}

/// CSS width:max-content bounded by the available viewport, including when the
/// description's trailing action row contains a flexible spacer.
struct NoticeIntrinsicWidth: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let view = subviews.first else { return .zero }
    let ideal = view.sizeThatFits(.unspecified)
    let width = min(ideal.width, proposal.width ?? ideal.width)
    return view.sizeThatFits(.init(width: width, height: nil))
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: .init(width: bounds.width, height: bounds.height))
  }
}

private struct NoticeActionStyle: ButtonStyle {
  let appearance: AppearancePreferences
  let hovered: Bool
  let focused: Bool
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    let roles = appearance.resolvedColors
    configuration.label.font(appearance.font(size: 12)).padding(.horizontal, 9).frame(height: 24)
      .foregroundStyle(roles["controlBackgroundOpaque"].color)
      .background(roles["textForeground"].color.opacity(enabled && (hovered || configuration.isPressed) ? 0.8 : 1),
        in: RoundedRectangle(cornerRadius: 12.5))
      .overlay(RoundedRectangle(cornerRadius: 12.5).strokeBorder(roles["border"].color, lineWidth: 1))
      .overlay(RoundedRectangle(cornerRadius: 12.5).strokeBorder(focused && enabled ? roles["borderFocus"].color : .clear, lineWidth: 2))
      .opacity(enabled ? 1 : 0.4)
  }
}

/// Native vectors in a 16-point box; no bundled third-party icon artwork.
private struct NoticeGlyph: View {
  var level: WorkspaceNotice.Level = .info
  var close = false
  var body: some View {
    Canvas { context, size in
      context.scaleBy(x: size.width / 16, y: size.height / 16)
      let style = StrokeStyle(lineWidth: level == .info ? 1.02734 : 1.05078, lineCap: .round, lineJoin: .round)
      if !close { context.stroke(Path(ellipseIn: CGRect(x: 2, y: 2, width: 12, height: 12)), with: .foreground, style: style) }
      var path = Path()
      if close || level == .error {
        let low: CGFloat = close ? 4.512 : 5.9, high = 16 - low
        path.move(to: CGPoint(x: low, y: low)); path.addLine(to: CGPoint(x: high, y: high))
        path.move(to: CGPoint(x: high, y: low)); path.addLine(to: CGPoint(x: low, y: high))
      } else if level == .success {
        path.move(to: CGPoint(x: 5.737, y: 8.648)); path.addLine(to: CGPoint(x: 7.347, y: 10.373))
        path.addLine(to: CGPoint(x: 10.263, y: 6.097))
      } else {
        let info = level == .info
        path.move(to: CGPoint(x: 8, y: info ? 8 : 5.88)); path.addLine(to: CGPoint(x: 8, y: info ? 10.667 : 7.79))
        context.fill(Path(ellipseIn: CGRect(x: 7.183, y: (info ? 5.666 : 10.121) - 0.817, width: 1.634, height: 1.634)), with: .foreground)
      }
      context.stroke(path, with: .foreground, style: style)
    }
  }
}
