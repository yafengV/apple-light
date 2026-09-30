import AppKit
import SwiftUI

private struct SettingsSearchPresentationKey: EnvironmentKey {
  static let defaultValue: SettingsSearchRequest? = nil
}

extension EnvironmentValues {
  var settingsSearchPresentation: SettingsSearchRequest? {
    get { self[SettingsSearchPresentationKey.self] }
    set { self[SettingsSearchPresentationKey.self] = newValue }
  }
}

struct SettingsSearchHighlightView: View {
  let token: UUID?
  @Environment(\.appAppearance) private var appearance
  @State private var startedAt: Date?

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 60, paused: startedAt == nil || appearance.shouldReduceMotion)) { timeline in
      let opacity = startedAt.map {
        appearance.shouldReduceMotion ? 1
          : SettingsSearchHighlight.opacity(elapsed: timeline.date.timeIntervalSince($0), reducedMotion: false)
      } ?? 0
      RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08 * opacity))
    }
    .allowsHitTesting(false).accessibilityHidden(true)
    .task(id: token) {
      guard token != nil else { startedAt = nil; return }
      startedAt = Date()
      try? await Task.sleep(for: .milliseconds(450))
      guard !Task.isCancelled else { return }
      startedAt = nil
    }
    .onDisappear { startedAt = nil }
  }
}

private struct SettingsSearchTarget: ViewModifier {
  let field: SettingsSearchField
  @Environment(\.settingsSearchPresentation) private var request

  func body(content: Content) -> some View {
    content
      .background {
        SettingsSearchHighlightView(token: request?.result.field == field ? request?.token : nil)
        SettingsSearchScrollAnchor(token: request?.result.field == field ? request?.token : nil)
      }
      .id(field.id)
  }
}

private struct SettingsSearchScrollAnchor: NSViewRepresentable {
  let token: UUID?

  func makeNSView(context: Context) -> Anchor { Anchor() }
  func updateNSView(_ view: Anchor, context: Context) { view.request(token) }

  final class Anchor: NSView {
    private var token: UUID?
    private var scrolledToken: UUID?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleScroll() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleScroll() }

    func request(_ token: UUID?) {
      self.token = token
      scheduleScroll()
    }

    private func scheduleScroll() {
      guard let token, scrolledToken != token else { return }
      DispatchQueue.main.async { [weak self] in self?.scrollToTarget(token) }
    }

    private func scrollToTarget(_ request: UUID) {
      guard token == request, scrolledToken != request,
        let scroll = sequence(first: superview, next: { $0?.superview })
          .compactMap({ $0 as? NSScrollView }).first,
        let document = scroll.documentView else { return }
      let target = convert(bounds, to: document)
      guard target.height > 0 else { return }
      let limit = max(0, document.bounds.height - scroll.contentSize.height)
      let y = min(limit, max(0, target.midY - scroll.contentSize.height / 2))
      scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: y))
      scroll.reflectScrolledClipView(scroll.contentView)
      scrolledToken = request
    }
  }
}

extension View {
  @ViewBuilder func settingsSearchTarget(_ field: SettingsSearchField, when enabled: Bool) -> some View {
    if enabled { modifier(SettingsSearchTarget(field: field)) } else { self }
  }
  func settingsSearchTarget(_ field: SettingsSearchField) -> some View {
    modifier(SettingsSearchTarget(field: field))
  }
}
