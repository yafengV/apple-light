import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class NavigationHistoryFailureTests: XCTestCase {
  private struct Fixture {
    let store: WorkspaceStore
    let source: URL
    let target: URL
    let failure: URL
    let gate: URL
    let reached: URL
  }
  private func fixture(stage: String) async throws -> Fixture {
    _ = NSApplication.shared
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath().standardizedFileURL
    let source = base.appendingPathComponent("Source"), target = base.appendingPathComponent("Target")
    for root in [source, target] { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    let executable = base.appendingPathComponent("fixture-agent"), failure = base.appendingPathComponent("fail")
    let gate = base.appendingPathComponent("gate"), reached = base.appendingPathComponent("reached")
    try Data(stage.utf8).write(to: failure)
    let script = #"""
    #!/usr/bin/python3
    import json, os, pathlib, sys, time
    project = sys.argv[sys.argv.index('--project') + 1]
    base = pathlib.Path(project).parent
    for line in sys.stdin:
        request = json.loads(line)
        method = request['method']
        if os.path.basename(project) == 'Target' and method == 'initialize' and (base / 'gate').exists():
            (base / 'reached').write_text('initialize')
            while (base / 'gate').exists(): time.sleep(0.01)
        response = {'jsonrpc': '2.0', 'id': request['id']}
        if os.path.basename(project) == 'Target' and (base / 'fail').exists() and (base / 'fail').read_text() == method:
            response['error'] = {'code': -32000, 'message': 'fixture scope preparation failed'}
        else:
            values = {'initialize': {'protocolVersion': 1},
                      'project.inspect': {'root': project, 'containers': [], 'swiftPackages': [], 'diagnostics': [], 'scanTruncated': False},
                      'config.get': {}, 'run.list': [], 'environment.list': [], 'run.events': {'events': []}}
            response['result'] = values.get(method, {})
        print(json.dumps(response), flush=True)
    """#
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let store = WorkspaceStore(dataRoot: base.appendingPathComponent("Data"), agentExecutable: executable)
    await store.restore(); await store.open(source)
    XCTAssertTrue(store.connected, store.error ?? "")
    store.library.tasks = [.init(id: "source", project: source.path, title: "Source", runIDs: []),
      .init(id: "target", project: target.path, title: "Target", runIDs: [])]
    store.applyTaskSelection(store.library.tasks[0]); store.draft = "source draft"
    store.workspace.fileText = "source preview"; store.showingInspector = true
    store.saveLibrary()
    addTeardownBlock { @MainActor in
      try? FileManager.default.removeItem(at: gate)
      try? FileManager.default.removeItem(at: failure)
      await store.shutdown()
      try? FileManager.default.removeItem(at: base)
    }
    return .init(store: store, source: source, target: target, failure: failure, gate: gate, reached: reached)
  }

  private func checkFailure(_ method: String) async throws {
    for back in [true, false] {
      for draft in [false, true] {
        let f = try await fixture(stage: method), store = f.store
        let owner = "new:\(f.target.path):link:\(UUID().uuidString)"
        store.library.drafts[owner] = "target linked draft"
        let target = TaskLocation(project: f.target.path, run: draft ? nil : "target", draftOwner: draft ? owner : nil)
        let origin = store.currentTaskLocation, previous = TaskLocation(project: f.source.path, run: "older")
        store.navigationBack = back ? [previous, target] : [previous]
        store.navigationForward = back ? [previous] : [previous, target]
        let oldBack = store.navigationBack, oldForward = store.navigationForward
        let layout = store.workspaceTabLayoutSnapshot, activeOwner = store.workspaceLayoutActiveOwner
        await store.navigate(back: back)
        XCTAssertEqual(store.navigationBack, oldBack, "\(method) back=\(back) draft=\(draft)")
        XCTAssertEqual(store.navigationForward, oldForward)
        XCTAssertEqual(store.currentTaskLocation, origin); XCTAssertEqual(store.draft, "source draft")
        XCTAssertEqual(store.workspace.fileText, "source preview"); XCTAssertTrue(store.showingInspector)
        XCTAssertEqual(store.workspaceTabLayoutSnapshot, layout); XCTAssertEqual(store.workspaceLayoutActiveOwner, activeOwner)
        XCTAssertFalse(store.connected); XCTAssertNotNil(store.error); XCTAssertFalse(store.busy)
        try FileManager.default.removeItem(at: f.failure)
        await store.navigate(back: back)
        XCTAssertEqual(store.project?.path, f.target.path)
        if draft { XCTAssertEqual(store.draftKey, owner); XCTAssertEqual(store.draft, "target linked draft") }
        else { XCTAssertEqual(store.selectedTask?.id, "target") }
        XCTAssertEqual(store.navigationBack, back ? [previous] : oldBack + [origin])
        XCTAssertEqual(store.navigationForward, back ? oldForward + [origin] : [previous])
      }
    }
  }

  func testInitializeFailureKeepsBothHistoryStacksAndRetryDestination() async throws { try await checkFailure("initialize") }
  func testInspectionFailureKeepsBothHistoryStacksAndRetryDestination() async throws { try await checkFailure("project.inspect") }
  func testConfigFailureKeepsBothHistoryStacksAndRetryDestination() async throws { try await checkFailure("config.get") }
  func testRunListFailureKeepsBothHistoryStacksAndRetryDestination() async throws { try await checkFailure("run.list") }

  private func waitForGate(_ fixture: Fixture) async throws {
    for _ in 0..<120 where !FileManager.default.fileExists(atPath: fixture.reached.path) {
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.reached.path))
  }

  func testPendingScopeDoesNotMoveHistoryAndDuplicateNavigationIsIgnored() async throws {
    let f = try await fixture(stage: "none"), store = f.store
    let target = TaskLocation(project: f.target.path, run: "target"), origin = store.currentTaskLocation
    store.navigationBack = [target]; store.navigationForward = [origin]
    try Data().write(to: f.gate)
    let navigation = Task { await store.navigate(back: true) }
    try await waitForGate(f)
    XCTAssertEqual(store.navigationBack, [target]); XCTAssertEqual(store.navigationForward, [origin])
    XCTAssertFalse(store.commandEnabled("back")); XCTAssertFalse(store.commandEnabled("forward"))
    await store.navigate(back: false)
    XCTAssertEqual(store.navigationBack, [target]); XCTAssertEqual(store.navigationForward, [origin])
    try FileManager.default.removeItem(at: f.gate); await navigation.value
    XCTAssertTrue(store.navigationBack.isEmpty); XCTAssertEqual(store.navigationForward, [origin, origin])
    XCTAssertEqual(store.selectedTask?.id, "target"); XCTAssertFalse(store.navigatingWorkspaceHistory)
    XCTAssertTrue(store.commandEnabled("forward"))
  }

  func testChangedHistoryDuringScopePreparationCannotBePoppedByOldRequest() async throws {
    let f = try await fixture(stage: "none"), store = f.store
    store.navigationBack = [.init(project: f.target.path, run: "target")]
    try Data().write(to: f.gate)
    let navigation = Task { await store.navigate(back: true) }
    try await waitForGate(f)
    store.recordNavigation(.init(project: f.source.path, run: "new action"))
    let back = store.navigationBack, forward = store.navigationForward
    try FileManager.default.removeItem(at: f.gate); await navigation.value
    XCTAssertEqual(store.navigationBack, back); XCTAssertEqual(store.navigationForward, forward)
    XCTAssertNotEqual(store.selection, "target"); XCTAssertFalse(store.navigatingWorkspaceHistory)
    XCTAssertEqual(store.project?.path, f.source.path); XCTAssertEqual(store.draft, "source draft")
  }

  func testAlreadyCancelledNavigationLeavesCurrentPageAndHistoryUntouched() async throws {
    let f = try await fixture(stage: "none"), store = f.store
    let origin = store.currentTaskLocation, target = TaskLocation(project: f.target.path, run: "target")
    store.navigationBack = [target]; store.navigationForward = [target]
    for back in [true, false] {
      let navigation = Task { await store.navigate(back: back) }
      navigation.cancel(); await navigation.value
      XCTAssertEqual(store.navigationBack, [target]); XCTAssertEqual(store.navigationForward, [target])
      XCTAssertEqual(store.currentTaskLocation, origin); XCTAssertTrue(store.connected)
      XCTAssertFalse(store.navigatingWorkspaceHistory)
    }
  }

  func testCancellationDuringPreparationDoesNotConsumeHistoryOrSelectTarget() async throws {
    let f = try await fixture(stage: "none"), store = f.store
    let target = TaskLocation(project: f.target.path, run: "target"), origin = store.currentTaskLocation
    store.navigationBack = [target]; store.navigationForward = [origin]
    try Data().write(to: f.gate)
    let navigation = Task { await store.navigate(back: true) }
    try await waitForGate(f); navigation.cancel()
    try FileManager.default.removeItem(at: f.gate); await navigation.value
    XCTAssertEqual(store.navigationBack, [target]); XCTAssertEqual(store.navigationForward, [origin])
    XCTAssertNotEqual(store.selection, "target"); XCTAssertFalse(store.navigatingWorkspaceHistory)
    XCTAssertEqual(store.project?.path, f.source.path); XCTAssertEqual(store.draft, "source draft")
    // Cancelled preparation preserves the source page. Retry still selects the
    // retained target and moves the history exactly once.
    await store.navigate(back: true)
    XCTAssertEqual(store.selectedTask?.id, "target"); XCTAssertTrue(store.navigationBack.isEmpty)
    XCTAssertEqual(store.navigationForward.count, 2)
  }

  func testInvalidOrMismatchedDraftTargetCannotConsumeHistory() async throws {
    let f = try await fixture(stage: "none"), store = f.store
    let origin = store.currentTaskLocation
    for owner in ["new:", "new:\(f.source.path):link:\(UUID().uuidString)"] {
      let target = TaskLocation(project: f.target.path, run: nil, draftOwner: owner)
      store.navigationBack = [target]; store.navigationForward = [origin]
      await store.navigate(back: true)
      XCTAssertEqual(store.navigationBack, [target]); XCTAssertEqual(store.navigationForward, [origin])
      XCTAssertEqual(store.currentTaskLocation, origin); XCTAssertEqual(store.draft, "source draft")
      XCTAssertTrue(store.connected); XCTAssertFalse(store.navigatingWorkspaceHistory)
    }
  }

  func testActualMainPageRetainsNativeEditorAndDraftOnHistoryOpenFailure() async throws {
    let f = try await fixture(stage: "config.get"), store = f.store
    try "file content".write(to: f.source.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    XCTAssertTrue(store.openFileTab("file.txt"))
    let tab = try XCTUnwrap(store.focusedWorkspaceContentTab), editor = store.fileTabWorkspace(tab)
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 760),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = NSHostingView(rootView: AppContentView(store: store))
    defer { window.contentView = nil; window.close() }
    func preview(_ view: NSView?) -> FilePreviewTextView? {
      guard let view else { return nil }
      if let result = view as? FilePreviewTextView { return result }
      return view.subviews.lazy.compactMap { preview($0) }.first
    }
    for _ in 0..<80 where preview(window.contentView)?.string != "file content" {
      try await Task.sleep(for: .milliseconds(25)); window.contentView?.layoutSubtreeIfNeeded()
    }
    let native = try XCTUnwrap(preview(window.contentView))
    editor.beginEditingSelectedFile(); editor.editSelectedFile("unsaved editor draft")
    let origin = store.currentTaskLocation, target = TaskLocation(project: f.target.path, run: "target")
    store.navigationBack = [target]; store.navigationForward = []
    await store.navigate(back: true)
    try await Task.sleep(for: .milliseconds(50)); window.contentView?.layoutSubtreeIfNeeded()
    XCTAssertEqual(store.currentTaskLocation, origin); XCTAssertEqual(store.draft, "source draft")
    XCTAssertEqual(store.focusedWorkspaceContentTab, tab)
    XCTAssertTrue(preview(window.contentView) === native); XCTAssertEqual(native.string, "unsaved editor draft")
    XCTAssertTrue(editor.selectedFileEditor?.hasUnsavedChanges == true)
    XCTAssertEqual(store.navigationBack, [target]); XCTAssertTrue(store.navigationForward.isEmpty)
    XCTAssertFalse(window.isVisible)
  }
}
