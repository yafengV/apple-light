import AppKit
import SwiftUI
import Observation
import XCTest
@testable import ShipiOS

final class SettingsLayoutTests: XCTestCase {
  func testSearchHighlightExpiresAndReducedMotionHasNoFade() {
    XCTAssertEqual(SettingsSearchHighlight.opacity(elapsed: 0, reducedMotion: false), 1)
    XCTAssertEqual(SettingsSearchHighlight.opacity(elapsed: -0.01, reducedMotion: false), 0)
    let samples = stride(from: 0.0, through: 0.45, by: 0.01).map {
      SettingsSearchHighlight.opacity(elapsed: $0, reducedMotion: false)
    }
    XCTAssertTrue(zip(samples, samples.dropFirst()).allSatisfy { $0 >= $1 })
    XCTAssertGreaterThan(SettingsSearchHighlight.opacity(elapsed: 0.2, reducedMotion: false), 0)
    XCTAssertLessThan(SettingsSearchHighlight.opacity(elapsed: 0.2, reducedMotion: false), 1)
    XCTAssertEqual(SettingsSearchHighlight.opacity(elapsed: 0.45, reducedMotion: false), 0)
    XCTAssertEqual(SettingsSearchHighlight.opacity(elapsed: 0.44, reducedMotion: true), 1)
    XCTAssertEqual(SettingsSearchHighlight.opacity(elapsed: 0.45, reducedMotion: true), 0)
  }

  @MainActor func testSharedFormUsesOneScrollDocumentAtNormalAndCompactWidths() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 816, height: 500),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: SampleSettingsForm())
    window.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: 816, height: 500)
    try await Task.sleep(for: .milliseconds(350))
    host.layoutSubtreeIfNeeded()
    let scrolls = scrollViews(in: host)
    XCTAssertEqual(scrolls.count, 1, "The page title must not require a second scroll container")
    let scroll = try XCTUnwrap(scrolls.first)
    let document = try XCTUnwrap(scroll.documentView)
    XCTAssertGreaterThan(document.frame.height, scroll.contentSize.height + 400)
    XCTAssertLessThanOrEqual(document.frame.width, scroll.contentSize.width + 1)
    let top = try snapshot(host, named: "settings-form-top")
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 280))
    scroll.reflectScrolledClipView(scroll.contentView)
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    XCTAssertEqual(scroll.contentView.bounds.origin.y, 280, accuracy: 1)
    let scrolled = try snapshot(host, named: "settings-form-scrolled")
    XCTAssertNotEqual(top, scrolled)

    window.setContentSize(NSSize(width: 550, height: 500))
    host.frame.size = NSSize(width: 550, height: 500)
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    XCTAssertEqual(scrollViews(in: host).count, 1)
    XCTAssertLessThanOrEqual(document.frame.width, scroll.contentSize.width + 1)
    _ = try snapshot(host, named: "settings-form-compact")
  }

  @MainActor func testReducedMotionPulseExpiresRetriggersAndOldTimerCannotClearNewPulse() async throws {
    _ = NSApplication.shared
    let state = PulseTestState()
    var appearance = AppearancePreferences(); appearance.reduceMotion = .on
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 60),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: PulseTestView(state: state)
      .environment(\.appAppearance, appearance).environment(\.colorScheme, .light))
    window.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: 160, height: 60)
    try await Task.sleep(for: .milliseconds(100))
    let baseline = try brightness(host)
    state.token = UUID()
    try await Task.sleep(for: .milliseconds(80))
    let active = try brightness(host)
    XCTAssertLessThan(active, baseline - 0.03)
    try await Task.sleep(for: .milliseconds(450))
    XCTAssertEqual(try brightness(host), baseline, accuracy: 0.01)

    state.token = UUID()
    try await Task.sleep(for: .milliseconds(300))
    state.token = UUID()
    try await Task.sleep(for: .milliseconds(220))
    XCTAssertLessThan(try brightness(host), baseline - 0.03, "The cancelled previous timer must not clear a repeated search")
    state.token = nil
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(try brightness(host), baseline, accuracy: 0.01)
  }

  @MainActor func testActualPagesRenderWithIsolatedDataAtMinimumWindowSize() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.notifications = CompletionNotificationCenter(delivery: LayoutNotificationDelivery())
    store.sshHostsLoaded = true
    store.destination = .settings
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: RuntimeSettingsView(store: store))
    window.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: 960, height: 600)
    try await Task.sleep(for: .milliseconds(350))
    for page in SettingsNavigation.pages {
      store.settingsPage = page
      try await Task.sleep(for: .milliseconds(100))
      host.layoutSubtreeIfNeeded()
      let image = try snapshot(host, named: "page-" + page.rawValue)
      XCTAssertGreaterThan(image.count, 5000, "Expected rendered content for \(page.rawValue)")
    }
  }

  @MainActor func testSpecialPagesHaveOneScrollDocumentWithPopulatedLists() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.destination = .settings
    store.sshHostsLoaded = true
    store.mcpServersLoaded = true
    store.pluginsLoaded = true
    store.sshHosts = (0..<30).map { SSHHost(alias: "build-host-\($0)", hostName: "localhost") }
    store.connectionSettingsSection = .ssh
    store.library.tasks = (0..<30).map {
      WorkspaceTask(id: "archived-\($0)", project: "/test/project", title: "归档任务 \($0)", runIDs: [],
        archived: true, archivedAt: Date(timeIntervalSince1970: Double($0)))
    }
    store.pluginPreferences.installed = (0..<30).map {
      .init(id: "test-\($0)", name: "插件 \($0)", summary: "测试插件", version: "1", enabled: false,
        installedAt: Date(), components: .init(skills: 1, mcpServers: 1))
    }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let cases: [(SettingsPage, String, AnyView)] = [
      (.plugins, "plugins", AnyView(PluginSettingsView(store: store))),
      (.connections, "connections", AnyView(ConnectionSettingsView(store: store))),
      (.shortcuts, "shortcuts", AnyView(ShortcutSettingsView(store: store))),
      (.archived, "archived", AnyView(ArchivedTasksSettingsView(store: store)))
    ]
    for (page, name, view) in cases {
      store.settingsPage = page
      store.pluginSettingsSection = .plugins
      let host = NSHostingView(rootView: view)
      window.contentView = host
      host.frame.size = NSSize(width: 700, height: 500)
      try await Task.sleep(for: .milliseconds(200))
      host.layoutSubtreeIfNeeded()
      let scrolls = scrollViews(in: host)
      XCTAssertEqual(scrolls.count, 1, "Nested scrolling in \(name)")
      let scroll = try XCTUnwrap(scrolls.first)
      let document = try XCTUnwrap(scroll.documentView)
      XCTAssertGreaterThan(document.frame.height, scroll.contentSize.height + 200, name)
      XCTAssertLessThanOrEqual(document.frame.width, scroll.contentSize.width + 1, name)
      _ = try snapshot(host, named: name + "-populated-top")
      scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
      scroll.reflectScrolledClipView(scroll.contentView)
      try await Task.sleep(for: .milliseconds(100))
      _ = try snapshot(host, named: name + "-populated-scrolled")
      if page == .archived {
        window.setContentSize(NSSize(width: 400, height: 500))
        host.frame.size = NSSize(width: 400, height: 500)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(document.frame.width, scroll.contentSize.width + 1)
        _ = try snapshot(host, named: "archived-compact")
        window.setContentSize(NSSize(width: 700, height: 500))
      }
      if page == .plugins {
        for section in [PluginSettingsSection.mcpServers, .skills] {
          store.pluginSettingsSection = section
          try await Task.sleep(for: .milliseconds(100))
          host.layoutSubtreeIfNeeded()
          XCTAssertEqual(scrollViews(in: host).count, 1, "Nested scrolling in plugin tab")
          scroll.contentView.scroll(to: .zero)
          scroll.reflectScrolledClipView(scroll.contentView)
          try await Task.sleep(for: .milliseconds(100))
          _ = try snapshot(host, named: "plugins-" + section.rawValue)
        }
      }
    }
  }

  @MainActor func testSearchControlsPinWhilePageHeadingScrollsAway() async throws {
    _ = NSApplication.shared
    let titleProbe = NSView(), controlsProbe = NSView()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: SettingsScrollPage(title: "滚动标题", pinsControls: true) {
      LayoutPositionProbe(view: titleProbe).frame(width: 1, height: 20)
    } controls: {
      TextField("搜索", text: .constant("")).frame(height: 30)
        .overlay(LayoutPositionProbe(view: controlsProbe))
    } content: {
      ForEach(0..<40) { Text("内容 \($0)").frame(height: 50) }
    })
    window.contentView = host
    host.frame.size = NSSize(width: 700, height: 500)
    try await Task.sleep(for: .milliseconds(150))
    host.layoutSubtreeIfNeeded()
    let scroll = try XCTUnwrap(scrollViews(in: host).first)
    func top(_ view: NSView) -> CGFloat {
      let rect = view.convert(view.bounds, to: host)
      return host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
    }
    XCTAssertGreaterThan(top(titleProbe), 0)
    XCTAssertGreaterThan(top(controlsProbe), 50)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
    scroll.reflectScrolledClipView(scroll.contentView)
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    XCTAssertLessThan(top(titleProbe), -200)
    XCTAssertGreaterThanOrEqual(top(controlsProbe), 0)
    XCTAssertLessThan(top(controlsProbe), 20)
  }

  @MainActor private func brightness(_ view: NSView) throws -> CGFloat {
    view.layoutSubtreeIfNeeded()
    let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: image)
    let color = try XCTUnwrap(image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
    return color.redComponent
  }

  @MainActor private func scrollViews(in view: NSView) -> [NSScrollView] {
    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
  }

  @MainActor private func snapshot(_ view: NSView, named name: String) throws -> Data {
    let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: image)
    let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
    if let path = ProcessInfo.processInfo.environment["SHIPIOS_SETTINGS_SNAPSHOTS"] {
      let directory = URL(fileURLWithPath: path)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: directory.appendingPathComponent(name + ".png"))
    }
    return data
  }
}

private struct LayoutPositionProbe: NSViewRepresentable {
  let view: NSView
  func makeNSView(context: Context) -> NSView { view }
  func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor @Observable private final class PulseTestState { var token: UUID? }
@MainActor private struct LayoutNotificationDelivery: NotificationDelivery {
  func permission() async -> NotificationPermission { .notDetermined }
  func requestPermission() async throws { XCTFail("Layout rendering must not request system permission") }
  func post(_ notice: CompletionNotice) async throws { XCTFail("Layout rendering must not send a notification") }
}
private struct PulseTestView: View {
  let state: PulseTestState
  var body: some View {
    Color.white.overlay(SettingsSearchHighlightView(token: state.token))
  }
}

private struct SampleSettingsForm: View {
  var body: some View {
    Form {
      Section("输入") {
        Toggle("显示教育提示", isOn: .constant(true))
        Picker("发送快捷键", selection: .constant(0)) { Text("Command + Enter").tag(0) }
        Text("设置标题与下方内容一起滚动。").font(.caption).foregroundStyle(.secondary)
      }
      ForEach(0..<14) { index in
        Section("示例设置 \(index)") {
          TextField("分支前缀", text: .constant("codex/"))
          Toggle("启用", isOn: .constant(true))
        }
      }
    }
    .settingsFormStyle()
    .environment(\.settingsPageTitle, "通用")
  }
}
