import AppKit

/// App-level icon changes stay outside the SwiftUI view lifecycle.
@MainActor final class DockIconController {
  private var preference = DockIconPreference.appDefault
  private var observation: NSKeyValueObservation?
  private var observationRevision = UUID()
  private let systemDark: @MainActor () -> Bool
  private let install: @MainActor (NSImage) -> Void
  private var applied: String?

  init(systemDark: @escaping @MainActor () -> Bool = {
    NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
  }, install: @escaping @MainActor (NSImage) -> Void = { NSApp.applicationIconImage = $0 }) {
    self.systemDark = systemDark; self.install = install
  }

  func start() {
    guard observation == nil else { return }
    let revision = UUID(); observationRevision = revision
    observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
      Task { @MainActor [weak self] in
        guard let self, self.observation != nil, self.observationRevision == revision else { return }
        self.refresh()
      }
    }
    refresh()
  }
  func apply(_ preference: DockIconPreference) {
    self.preference = preference
    refresh()
  }
  func refresh() {
    let dark = preference == .adaptive && systemDark()
    let key = preference.rawValue + (dark ? ":dark" : ":light")
    guard key != applied else { return }
    install(DockIconArtwork.image(preference, dark: dark)); applied = key
  }
  func stop() { observationRevision = UUID(); observation?.invalidate(); observation = nil }
}

/// ShipiOS artwork; no reference application's branding or private resources.
@MainActor enum DockIconArtwork {
  static func image(_ preference: DockIconPreference, dark: Bool) -> NSImage {
    NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { rect in
      let card = rect.insetBy(dx: 88, dy: 88)
      let shape = NSBezierPath(roundedRect: card, xRadius: 188, yRadius: 188)
      if preference == .appDefault {
        NSGradient(starting: NSColor(srgbRed: 0.36, green: 0.24, blue: 0.91, alpha: 1),
          ending: NSColor(srgbRed: 0.06, green: 0.54, blue: 0.95, alpha: 1))?.draw(in: shape, angle: -50)
      } else {
        (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.96, alpha: 1)).setFill(); shape.fill()
      }
      let ink = preference == .appDefault || dark ? NSColor.white : NSColor(white: 0.13, alpha: 1)
      // A vector paper plane remains crisp at every Dock and preview scale.
      let plane = NSBezierPath()
      plane.move(to: NSPoint(x: 270, y: 528)); plane.line(to: NSPoint(x: 760, y: 742))
      plane.line(to: NSPoint(x: 586, y: 266)); plane.line(to: NSPoint(x: 496, y: 446))
      plane.line(to: NSPoint(x: 680, y: 664)); plane.line(to: NSPoint(x: 458, y: 482))
      plane.close(); ink.setFill(); plane.fill()
      return true
    }
  }
}
