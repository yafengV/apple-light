import AppKit
import SwiftUI

struct WorkspaceNoticeCard: View {
  let store: WorkspaceStore
  let notice: WorkspaceNotice
  @FocusState.Binding var focused: String?
  var interaction: NoticeInteractionState? = nil
  var isFirst = false
  var isLast = false
  var onSwipeDismiss: (UUID) -> Void = { _ in }
  @Environment(\.appAppearance) private var appearance
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var closeHovered = false
  @State private var actionHovered = false
  @State private var swipe = NoticeSwipeGesture()
  @State private var swipeOffset: CGFloat = 0
  @State private var swipeOut = false
  @State private var cardWidth: CGFloat = 0
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
              .disabled(swipeOffset != 0 || swipeOut)
              .focusable().focusEffectDisabled()
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
    .focusable().focusEffectDisabled()
    .focused($focused, equals: notice.generation.uuidString + "-row")
    .onKeyPress(keys: [.tab], phases: .down) { press in
      let row = notice.generation.uuidString + "-row"
      let actionEnabled = notice.taskID != nil && !((store.hasSettingsConfirmation && store.appearanceThemeImport == nil)
        || store.presentedOverlay != nil)
      let last = notice.generation.uuidString + (actionEnabled && notice.description != nil ? "-view"
        : notice.level == .pending ? "-row" : "-close")
      if (isFirst && focused == row && press.modifiers == .shift)
        || (isLast && focused == last && press.modifiers.isEmpty) {
        focused = nil
        interaction?.returnToPreviousFocus()
        return .handled
      }
      if press.modifiers.isEmpty || press.modifiers == .shift { interaction?.beginCardTabMovement() }
      return .ignored
    }
    .overlay(RoundedRectangle(cornerRadius: 15)
      .strokeBorder(focused == notice.generation.uuidString + "-row" ? resolved.resolvedColors["borderFocus"].color : .clear,
        lineWidth: 2).padding(-2).allowsHitTesting(false))
    .background(GeometryReader { proxy in
      Color.clear.preference(key: NoticeWidthKey.self, value: proxy.size.width)
    })
    .onPreferenceChange(NoticeWidthKey.self) { cardWidth = $0 }
    .offset(x: swipeOffset)
    .opacity(swipeOut ? 0 : 1)
    .allowsHitTesting(!swipeOut)
    .onContinuousHover { phase in
      switch phase {
      case .active: interaction?.pointerMoved(over: notice.generation)
      case .ended: interaction?.pointerLeft(notice.generation)
      }
    }
    .simultaneousGesture(DragGesture(minimumDistance: 0)
      .onChanged { value in
        guard notice.level != .pending, !swipeOut else { return }
        if swipe.startedAt == nil {
          swipe.begin(at: value.time.timeIntervalSinceReferenceDate,
            onButton: actionHovered || closeHovered)
          interaction?.setInteracting(true)
        }
        swipeOffset = swipe.move(x: value.translation.width, y: value.translation.height)
      }
      .onEnded { value in
        guard swipe.startedAt != nil else { return }
        interaction?.setInteracting(false)
        let dismiss = swipe.shouldDismiss(at: value.time.timeIntervalSinceReferenceDate)
        let swipeDirection: CGFloat = swipe.horizontalOffset < 0 ? -1 : 1
        swipe = NoticeSwipeGesture()
        if dismiss {
          onSwipeDismiss(notice.generation)
          if reduceMotion {
            swipeOut = true
            store.notices.dismiss(notice.id, generation: notice.generation)
          } else {
            withAnimation(.easeOut(duration: 0.2)) {
              swipeOut = true
              swipeOffset += swipeDirection * max(356, cardWidth)
            }
            Task { @MainActor in
              try? await Task.sleep(for: .milliseconds(200))
              store.notices.dismiss(notice.id, generation: notice.generation)
            }
          }
        } else {
          withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.4)) { swipeOffset = 0 }
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
    Button(notice.actionTitle) { Task { await store.openNoticeTask(notice) } }
      .buttonStyle(NoticeActionStyle(appearance: resolved, hovered: actionHovered,
        focused: focused == notice.generation.uuidString + "-view"))
      .focusable().focusEffectDisabled()
      .focused($focused, equals: notice.generation.uuidString + "-view")
      .onHover { actionHovered = $0 }
      .disabled((store.hasSettingsConfirmation && store.appearanceThemeImport == nil)
        || store.presentedOverlay != nil || swipeOffset != 0 || swipeOut)
  }
}

private struct NoticeWidthKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
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
