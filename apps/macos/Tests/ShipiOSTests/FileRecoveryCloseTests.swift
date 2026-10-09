import AppKit
import Observation
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class FileRecoveryCloseTests: XCTestCase {
  private func fixture() throws -> (WorkspaceStore, URL) {
    _ = NSApplication.shared
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let root = base.appendingPathComponent("Project")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "original".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    let store = WorkspaceStore(dataRoot: base.appendingPathComponent("Data"))
    store.libraryLoaded = true; store.scopeLoaded = true; store.connected = true
    store.project = root; store.workspace.setProject(root); store.bindFileEditorRecovery(to: store.workspace)
    store.library.tasks = [.init(id: "task", project: root.path, title: "Task", runIDs: [])]
    store.selection = "task"; store.restoreWorkspaceTabLayout(); store.saveLibrary()
    addTeardownBlock { @MainActor in
      for resources in store.taskWindowResources.allObjects { resources.shutdown() }
      store.workspace.setProject(nil); store.workspace.browser.shutdown(); store.workspace.terminals.shutdown()
      for editor in store.fileTabWorkspaces.values { editor.setProject(nil) }
      try? FileManager.default.removeItem(at: base)
    }
    return (store, root)
  }

  private func blockWrites(_ store: WorkspaceStore) throws -> () throws -> Void {
    let file = store.dataRoot.appendingPathComponent("workspace.json"), bytes = try Data(contentsOf: file)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    return { try FileManager.default.removeItem(at: file); try bytes.write(to: file, options: .atomic) }
  }

  private func mount(_ view: some View) async throws -> NSWindow {
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1120, height: 780),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = NSHostingView(rootView: view)
    try await Task.sleep(for: .milliseconds(150)); window.contentView?.layoutSubtreeIfNeeded()
    return window
  }

  private func child(_ store: WorkspaceStore) async throws -> (TaskWindowResources, DeveloperWorkspace) {
    let resources = TaskWindowResources(); resources.prepare("task", store: store)
    let tabs = try XCTUnwrap(resources.tasks["task"]); XCTAssertTrue(tabs.openFile("file.txt"))
    let editor = resources.fileWorkspace(try XCTUnwrap(tabs.focused))
    editor.setProject(tabs.panels.workspace.root); await editor.openFile("file.txt")
    editor.beginEditingSelectedFile(); editor.editSelectedFile("child draft")
    addTeardownBlock { @MainActor in resources.shutdown() }
    return (resources, editor)
  }

  func testResourceShutdownFailureKeepsFileAndLiveTerminalUntilRetry() async throws {
    let (store, _) = try fixture(), (resources, editor) = try await child(store)
    let tabs = try XCTUnwrap(resources.tasks["task"]); tabs.newTerminal()
    let terminal = try XCTUnwrap(tabs.panels.terminal)
    let repair = try blockWrites(store)
    resources.shutdown()
    XCTAssertTrue(resources.tasks["task"] === tabs)
    XCTAssertNotNil(editor.root); XCTAssertEqual(editor.fileText, "child draft")
    XCTAssertTrue(terminal.view.process.running)
    try repair(); resources.shutdown()
    XCTAssertTrue(resources.tasks.isEmpty); XCTAssertFalse(terminal.view.process.running)
    let saved = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(saved.fileEditorRecovery.values.first?.text, "child draft")
  }

  func testStoreShutdownFailureDoesNotStartTeardownAndCanRetry() async throws {
    let (store, _) = try fixture(), (resources, _) = try await child(store)
    await store.workspace.openFile("file.txt"); store.workspace.beginEditingSelectedFile()
    store.workspace.editSelectedFile("main draft")
    let repair = try blockWrites(store)
    var teardownCount = 0
    let shutdownChanges = CloseCounter()
    withObservationTracking { _ = store.shuttingDown } onChange: {
      MainActor.assumeIsolated { shutdownChanges.value += 1 }
    }
    let rejected = await store.shutdown(beforeTeardown: { teardownCount += 1 })
    XCTAssertFalse(rejected)
    XCTAssertEqual(teardownCount, 0); XCTAssertEqual(shutdownChanges.value, 0)
    XCTAssertFalse(store.shuttingDown); XCTAssertTrue(store.connected)
    XCTAssertTrue(store.scopeLoaded); XCTAssertFalse(resources.tasks.isEmpty)
    XCTAssertEqual(store.workspace.fileText, "main draft")
    try repair()
    let accepted = await store.shutdown(beforeTeardown: {
      teardownCount += 1
      store.workspace.editSelectedFile("too late")
    })
    XCTAssertTrue(accepted); XCTAssertEqual(teardownCount, 1); XCTAssertEqual(shutdownChanges.value, 1)
    XCTAssertEqual(store.workspace.fileText, "main draft")
    XCTAssertTrue(store.shuttingDown); XCTAssertFalse(store.connected)
    let saved = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    let drafts = try XCTUnwrap(saved.fileEditorRecovery.values.first).versions
    XCTAssertEqual(Set(drafts.map(\.text)), ["main draft", "child draft"])
  }

  func testActualMainWindowNativeCloseWaitsForDurableDraftAndRetries() async throws {
    let (store, root) = try fixture()
    XCTAssertTrue(store.openFileTab("file.txt"))
    let editor = store.fileTabWorkspace(try XCTUnwrap(store.focusedWorkspaceContentTab))
    editor.setProject(root); await editor.openFile("file.txt")
    editor.beginEditingSelectedFile(); editor.editSelectedFile("main tab draft")
    let window = try await mount(AppContentView(store: store))
    defer { window.contentView = nil; window.close() }
    let closeCount = CloseCounter()
    let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
      MainActor.assumeIsolated { closeCount.value += 1 }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    let repair = try blockWrites(store)
    window.performClose(nil)
    XCTAssertEqual(closeCount.value, 0); XCTAssertEqual(editor.fileText, "main tab draft")
    XCTAssertNotNil(store.error)
    try repair(); window.performClose(nil)
    XCTAssertEqual(closeCount.value, 1)
    let saved = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(saved.fileEditorRecovery[editor.editorKey(for: "file.txt")]?.text, "main tab draft")
  }

  func testActualTaskSceneNativeCloseRetainsItsEditorOnWriteFailure() async throws {
    let (store, _) = try fixture()
    let route = TaskWindowRoute(taskID: "task", dataRoot: store.dataRoot, windowID: "task-window")
    let window = try await mount(TaskWindowSceneView(store: store, route: .constant(route)))
    defer { window.contentView = nil; window.close() }
    for _ in 0..<60 where !store.taskWindowResources.allObjects.contains(where: { $0.id == route.id }) {
      try await Task.sleep(for: .milliseconds(25))
    }
    let resources = try XCTUnwrap(store.taskWindowResources.allObjects.first { $0.id == route.id })
    let tabs = try XCTUnwrap(resources.tasks["task"]); XCTAssertTrue(tabs.openFile("file.txt"))
    let editor = resources.fileWorkspace(try XCTUnwrap(tabs.focused))
    editor.setProject(tabs.panels.workspace.root); await editor.openFile("file.txt")
    editor.beginEditingSelectedFile(); editor.editSelectedFile("task scene draft")
    let closeCount = CloseCounter()
    let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
      MainActor.assumeIsolated { closeCount.value += 1 }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    let repair = try blockWrites(store)
    window.performClose(nil)
    XCTAssertEqual(closeCount.value, 0); XCTAssertFalse(resources.tasks.isEmpty)
    XCTAssertEqual(editor.fileText, "task scene draft")
    try repair(); window.performClose(nil)
    XCTAssertEqual(closeCount.value, 1)
    let saved = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertTrue(saved.fileEditorRecovery.values.contains { $0.text == "task scene draft" })
  }

  func testForcedNativeTaskCloseRetainsDraftUntilStorageRecovers() async throws {
    let (store, _) = try fixture()
    let route = TaskWindowRoute(taskID: "task", dataRoot: store.dataRoot, windowID: "forced-window")
    let window = try await mount(TaskWindowSceneView(store: store, route: .constant(route)))
    defer { window.contentView = nil; window.close() }
    let resources = try XCTUnwrap(store.taskWindowResources.allObjects.first { $0.id == route.id })
    let tabs = try XCTUnwrap(resources.tasks["task"]); XCTAssertTrue(tabs.openFile("file.txt"))
    let editor = resources.fileWorkspace(try XCTUnwrap(tabs.focused))
    editor.setProject(tabs.panels.workspace.root); await editor.openFile("file.txt")
    editor.beginEditingSelectedFile(); editor.editSelectedFile("forced close draft")
    let key = editor.editorKey(for: "file.txt")
    let repair = try blockWrites(store)
    window.close() // Deliberately bypasses windowShouldClose, as system teardown can.
    XCTAssertTrue(resources.tasks.isEmpty); XCTAssertNil(editor.root)
    XCTAssertTrue(store.pendingFileEditorRecoveryWorkspaces.values.contains { $0 === editor })
    XCTAssertEqual(editor.fileEditorSessions[key]?.text, "forced close draft")
    XCTAssertFalse(store.captureFileEditorRecovery(from: []))
    try repair()
    XCTAssertTrue(store.captureFileEditorRecovery(from: []))
    XCTAssertTrue(store.pendingFileEditorRecoveryWorkspaces.isEmpty); XCTAssertNil(store.fileEditorRecoveryError)
    let saved = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(saved.fileEditorRecovery[key]?.text, "forced close draft")
    XCTAssertEqual(saved.fileEditorRecovery[key]?.context?.windowID, route.id)
  }

  func testActualDetachedFileWindowCloseWaitsForItsDraftAndRetries() async throws {
    let (store, root) = try fixture(); XCTAssertTrue(store.openFileTab("file.txt"))
    let tab = try XCTUnwrap(store.focusedWorkspaceContentTab)
    let editor = store.fileTabWorkspace(tab)
    editor.setProject(root); await editor.openFile("file.txt")
    editor.beginEditingSelectedFile(); editor.editSelectedFile("detached draft")
    store.moveWorkspaceTab(tab.id, to: .detached)
    let route = try XCTUnwrap(store.detachedWorkspaceTabRoute(tab.id))
    let window = try await mount(WorkspaceTabWindowSceneView(store: store, route: .constant(route)))
    defer { window.contentView = nil; window.close() }
    let counter = CloseCounter()
    let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
      MainActor.assumeIsolated { counter.value += 1 }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    let repair = try blockWrites(store)
    window.performClose(nil)
    XCTAssertEqual(counter.value, 0); XCTAssertEqual(editor.fileText, "detached draft")
    try repair(); window.performClose(nil)
    XCTAssertEqual(counter.value, 1)
    let saved = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(saved.fileEditorRecovery[editor.editorKey(for: "file.txt")]?.text, "detached draft")
  }

  func testCleanUnrelatedWindowsCanCloseWhileAnotherDraftCannotPersist() async throws {
    let (store, _) = try fixture(), (_, editor) = try await child(store)
    let repair = try blockWrites(store)
    XCTAssertFalse(store.captureFileEditorRecovery(from: editor))
    XCTAssertTrue(store.prepareDetachedWindowClose("unrelated-browser"))
    let cleanResources = TaskWindowResources(); cleanResources.prepare("task", store: store, windowID: "clean-window")
    XCTAssertTrue(cleanResources.shutdown()); XCTAssertTrue(cleanResources.tasks.isEmpty)
    XCTAssertFalse(store.pendingFileEditorRecoveryWorkspaces.isEmpty)
    XCTAssertNotNil(store.fileEditorRecoveryError)
    try repair(); XCTAssertTrue(store.captureFileEditorRecovery(from: []))
  }

  func testMainWindowCloseDoesNotGateOnADetachedFileDraft() async throws {
    let (store, root) = try fixture(); XCTAssertTrue(store.openFileTab("file.txt"))
    let tab = try XCTUnwrap(store.focusedWorkspaceContentTab), editor = store.fileTabWorkspace(tab)
    editor.setProject(root); await editor.openFile("file.txt")
    editor.beginEditingSelectedFile(); editor.editSelectedFile("separate window draft")
    store.moveWorkspaceTab(tab.id, to: .detached)
    let repair = try blockWrites(store)
    XCTAssertFalse(store.prepareDetachedWindowClose(tab.id))
    XCTAssertTrue(store.prepareMainWindowClose())
    XCTAssertFalse(store.pendingFileEditorRecoveryWorkspaces.isEmpty)
    try repair(); XCTAssertTrue(store.prepareDetachedWindowClose(tab.id))
  }

  func testCloseVerifiesStorageEvenWhenDraftWasAlreadyCaptured() async throws {
    let (store, _) = try fixture(), (resources, editor) = try await child(store)
    XCTAssertTrue(store.captureFileEditorRecovery(from: editor))
    let repair = try blockWrites(store)
    XCTAssertFalse(resources.prepareToClose()); XCTAssertFalse(resources.tasks.isEmpty)
    try repair(); XCTAssertTrue(resources.shutdown())
    let saved = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(saved.fileEditorRecovery.values.first?.text, "child draft")
  }

  func testFailedDiscardCleanupRemainsPendingAfterEditorReleaseAndRetries() async throws {
    let (store, _) = try fixture(), (resources, editor) = try await child(store)
    XCTAssertTrue(store.captureFileEditorRecovery(from: editor))
    let key = editor.editorKey(for: "file.txt"), repair = try blockWrites(store)
    editor.discardAndCloseFile("file.txt")
    XCTAssertTrue(editor.pendingFileEditorRecoveryResolutions.contains(key))
    XCTAssertFalse(resources.shutdown(force: true)); XCTAssertNil(editor.root)
    try repair(); XCTAssertTrue(store.captureFileEditorRecovery(from: []))
    XCTAssertTrue(store.pendingFileEditorRecoveryWorkspaces.isEmpty)
    let saved = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertNil(saved.fileEditorRecovery[key])
  }

  func testPendingDiscardThenNewEditDoesNotResurrectDiscardedVersion() async throws {
    let (store, _) = try fixture(), (_, editor) = try await child(store)
    XCTAssertTrue(store.captureFileEditorRecovery(from: editor))
    let key = editor.editorKey(for: "file.txt"), repair = try blockWrites(store)
    editor.discardAndCloseFile("file.txt"); await editor.openFile("file.txt")
    editor.beginEditingSelectedFile(); editor.editSelectedFile("replacement draft")
    try repair(); XCTAssertTrue(store.captureFileEditorRecovery(from: []))
    let saved = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(saved.fileEditorRecovery[key]?.versions.map(\.text), ["replacement draft"])
    XCTAssertTrue(editor.pendingFileEditorRecoveryResolutions.isEmpty)
  }

  func testUnloadedLibraryDoesNotPretendDirtyEditorWasSaved() async throws {
    let (store, _) = try fixture(), (resources, editor) = try await child(store)
    store.libraryLoaded = false
    XCTAssertFalse(resources.prepareToClose()); XCTAssertEqual(editor.fileText, "child draft")
    XCTAssertTrue(store.pendingFileEditorRecoveryWorkspaces.values.contains { $0 === editor })
    store.libraryLoaded = true; XCTAssertTrue(resources.shutdown())
  }

  func testNativeDelegateVetoForwardingAndAttachmentRestoration() throws {
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.contentView = nil; window.delegate = nil; window.close() }
    let original = OriginalDelegate(); window.delegate = original
    var preparations = 0, closures = 0
    let attachment = FileRecoveryWindowCloseGuard.Attachment(prepare: { preparations += 1; return true }, didClose: { closures += 1 })
    window.contentView?.addSubview(attachment)
    XCTAssertTrue(window.delegate === attachment.proxy)
    original.allowClose = false; window.performClose(nil)
    XCTAssertEqual(preparations, 0); XCTAssertEqual(closures, 0)
    let selector = #selector(NSWindowDelegate.windowDidResize(_:))
    XCTAssertTrue(attachment.proxy.responds(to: selector))
    window.delegate?.windowDidResize?(Notification(name: NSWindow.didResizeNotification, object: window))
    XCTAssertEqual(original.resizes, 1)
    attachment.removeFromSuperview(); XCTAssertTrue(window.delegate === original)
    window.contentView?.addSubview(attachment); XCTAssertTrue(window.delegate === attachment.proxy)
    original.allowClose = true; window.performClose(nil)
    XCTAssertEqual(preparations, 2); XCTAssertEqual(closures, 1); XCTAssertEqual(original.closes, 1)
    let replacement = OriginalDelegate(); window.delegate = replacement
    attachment.detach(); XCTAssertTrue(window.delegate === replacement)
  }

  @MainActor private final class CloseCounter { var value = 0 }
  private final class OriginalDelegate: NSObject, NSWindowDelegate {
    var allowClose = true, resizes = 0, closes = 0
    func windowShouldClose(_ sender: NSWindow) -> Bool { allowClose }
    func windowDidResize(_ notification: Notification) { resizes += 1 }
    func windowWillClose(_ notification: Notification) { closes += 1 }
  }
}
