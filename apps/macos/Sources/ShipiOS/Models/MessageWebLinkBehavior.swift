import AppKit

enum MessageWebLinkPresentation: Equatable {
  case split, fullWidth, foregroundTab, backgroundTab
  var createsNewTab: Bool { self == .foregroundTab || self == .backgroundTab }
}

enum MessageWebLinkBehavior: Equatable {
  case external
  case download
  case inApp(MessageWebLinkPresentation)

  static func resolve(url: URL, click: WebLinkClick?, preference: WebLinkTarget,
    shortcut: ExternalBrowserLinkShortcut) -> Self {
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .external }
    let flags = click?.modifiers ?? []
    // The dedicated full-width gesture precedes both target preferences.
    if click?.button == 0, flags.intersection([.command, .control, .option, .shift]) == [.command, .option] {
      return .inApp(.fullWidth)
    }
    if shortcut.matches(click) { return .external }
    if click?.button == 0, flags.intersection([.command, .control, .option, .shift]) == .option {
      return .download
    }
    if click?.button == 1 || flags.contains(.command) {
      return .inApp(flags.contains(.shift) ? .foregroundTab : .backgroundTab)
    }
    return preference == .externalBrowser ? .external : .inApp(.split)
  }
}
