import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class ComposerNarrowLayoutTests: XCTestCase {
  func testCoreComposerFitsSplitPaneAndKeepsEditorInsideItsCard() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    defer { try? FileManager.default.removeItem(at: root) }
    var config = ModelConfiguration()
    config.baseURL = "http://127.0.0.1:9/v1"
    config.model = "a-service-model-with-a-long-name"
    config.apiProtocol = .codexResponses
    try store.saveModelConfiguration(config)
    store.library.tasks = [.init(id: "layout-task", project: "", title: "Layout", runIDs: ["layout-run"])]
    store.selection = "layout-run"
    store.draft = "保留布局草稿"
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 325, height: 360),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: ComposerView(store: store)
      .frame(maxWidth: .infinity, maxHeight: .infinity))
    host.sizingOptions = []
    window.contentView = host
    defer { window.contentView = nil; window.close() }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let named = AgentRuntimePreferences(namedProfile: .init(id: "custom-profile",
      description: "较长的项目权限配置说明", configTOML: ""))
    var focused = false
    for preferences in [AgentRuntimePreferences.askForApproval, named] {
      store.library.taskRuntimePreferences["layout-task"] = preferences
      for mode in [ChatMode.standard, .plan] {
        store.chatMode = mode
        for width: CGFloat in [325, 540, 325] {
          window.setContentSize(.init(width: width, height: 360))
          host.frame.size = .init(width: width, height: 360)
          try await Task.sleep(for: .milliseconds(100))
          host.layoutSubtreeIfNeeded()
          let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? ComposerNativeTextView }.first)
          let scroll = try XCTUnwrap(editor.enclosingScrollView)
          let rect = scroll.convert(scroll.bounds, to: host)
          XCTAssertGreaterThanOrEqual(rect.minX, 15, "Controls must not widen and center the entire composer outside its pane")
          XCTAssertLessThanOrEqual(rect.maxX, width - 15, "The input card must stay inside the split pane")
          XCTAssertGreaterThan(rect.width, width - 50)
          XCTAssertEqual(editor.string, "保留布局草稿")
          if focused {
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(editor.selectedRange(), .init(location: 2, length: 2))
          } else {
            XCTAssertTrue(window.makeFirstResponder(editor))
            editor.setSelectedRange(.init(location: 2, length: 2))
            focused = true
          }
        }
      }
    }
    XCTAssertFalse(window.isVisible)
    await store.shutdown()
  }
}
