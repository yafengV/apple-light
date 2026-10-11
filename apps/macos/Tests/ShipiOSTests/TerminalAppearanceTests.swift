import AppKit
import SwiftTerm
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class TerminalAppearanceTests: XCTestCase {
  private func window() -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 520, height: 220),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
  }

  private func settle(_ host: NSView) async throws {
    try await Task.sleep(for: .milliseconds(120))
    host.layoutSubtreeIfNeeded()
  }

  private func assertReadable(_ terminal: TerminalView, light: Bool,
    file: StaticString = #filePath, line: UInt = #line) {
    let background = terminal.getTerminal().backgroundColor
    let foreground = terminal.getTerminal().foregroundColor
    let bg = Double(background.red) / 65535
    let fg = Double(foreground.red) / 65535
    if light {
      XCTAssertGreaterThan(bg, 0.9, "Light app must not retain dark terminal background", file: file, line: line)
      XCTAssertLessThan(fg, 0.2, file: file, line: line)
    } else {
      XCTAssertLessThan(bg, 0.2, file: file, line: line)
      XCTAssertGreaterThan(fg, 0.8, file: file, line: line)
    }
    XCTAssertGreaterThan(abs(fg - bg), 0.7, file: file, line: line)
  }

  func testLiveTerminalThemeSwitchKeepsShellAndReadableRetainedOutput() async throws {
    let window = window(), originalAppearance = NSApp.appearance
    NSApp.appearance = NSAppearance(named: .darkAqua)
    let session = TerminalSession(root: FileManager.default.temporaryDirectory)
    defer { session.stop(); window.close(); NSApp.appearance = originalAppearance }
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    window.contentView = host
    let pid = session.view.process.shellPid
    session.view.feed(text: "\r\nTHEME RETAINED OUTPUT\r\n")
    for theme in ["dark", "light", "dark", "light"] {
      var appearance = AppearancePreferences(); appearance.theme = theme
      host.rootView = AnyView(TerminalHost(session: session, focus: nil, canFocus: { _ in false })
        .environment(\.appAppearance, appearance).preferredColorScheme(appearance.colorScheme))
      try await settle(host)
      assertReadable(session.view, light: theme == "light")
      XCTAssertTrue(session.view.process.running)
      XCTAssertEqual(session.view.process.shellPid, pid, "Appearance cannot restart the shell")
      XCTAssertTrue((0..<session.view.getTerminal().rows).contains {
        session.view.getTerminal().getLine(row: $0)?.translateToString().contains("THEME RETAINED OUTPUT") == true
      })
    }
    XCTAssertFalse(window.isVisible, "Hidden color regression, not actual window acceptance")
  }

  func testReadOnlyOutputUsesAppThemeAgainstOppositeSystemAppearanceAndCustomPalette() async throws {
    let window = window(), originalAppearance = NSApp.appearance
    defer { window.close(); NSApp.appearance = originalAppearance }
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    window.contentView = host
    func terminal(_ view: NSView) -> BackgroundOutputTerminalView? {
      if let view = view as? BackgroundOutputTerminalView { return view }
      return view.subviews.lazy.compactMap(terminal).first
    }
    var retained: BackgroundOutputTerminalView?
    for theme in ["light", "dark", "light"] {
      NSApp.appearance = NSAppearance(named: theme == "light" ? .darkAqua : .aqua)
      var appearance = AppearancePreferences(); appearance.theme = theme
      host.rootView = AnyView(BackgroundTerminalOutputHost(output: "READ ONLY OUTPUT")
        .environment(\.appAppearance, appearance).preferredColorScheme(appearance.colorScheme))
      try await settle(host)
      let view = try XCTUnwrap(terminal(host))
      if let retained { XCTAssertTrue(view === retained) }
      retained = view
      assertReadable(view, light: theme == "light")
      XCTAssertTrue(view.getTerminal().getLine(row: 0)?.translateToString().contains("READ ONLY OUTPUT") == true)
    }
    var appearance = AppearancePreferences(); appearance.theme = "light"
    appearance.light.background = "#123456"; appearance.light.foreground = "#ABCDEF"
    host.rootView = AnyView(BackgroundTerminalOutputHost(output: "READ ONLY OUTPUT")
      .environment(\.appAppearance, appearance).preferredColorScheme(.light))
    try await settle(host)
    let view = try XCTUnwrap(terminal(host))
    XCTAssertTrue(view === retained)
    // SwiftTerm truncates normalized channels to UInt16; allow one quantization step.
    XCTAssertEqual(Double(view.getTerminal().backgroundColor.red), Double(0x12 * 257), accuracy: 1)
    XCTAssertEqual(Double(view.getTerminal().backgroundColor.green), Double(0x34 * 257), accuracy: 1)
    XCTAssertEqual(Double(view.getTerminal().foregroundColor.blue), Double(0xEF * 257), accuracy: 1)
  }
}
