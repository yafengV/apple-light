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
      .background(SettingsSearchHighlightView(token: request?.result.field == field ? request?.token : nil))
      .id(field.id)
  }
}

extension View {
  func settingsSearchTarget(_ field: SettingsSearchField) -> some View {
    modifier(SettingsSearchTarget(field: field))
  }
}
