import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

final class HookSettingsTests: XCTestCase {
  private func fixture(_ configuration: String) throws -> (root: URL, data: URL, source: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-ui-\(UUID())")
    let source = root.appendingPathComponent("Source"), data = root.appendingPathComponent("Data")
    try FileManager.default.createDirectory(at: source.appendingPathComponent(".codex-plugin"), withIntermediateDirectories: true)
    try #"{"id":"hook-fixture","name":"Hook Fixture"}"#.write(
      to: source.appendingPathComponent(".codex-plugin/plugin.json"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: source.appendingPathComponent("hooks"), withIntermediateDirectories: true)
    try configuration.write(to: source.appendingPathComponent("hooks/hooks.json"), atomically: true, encoding: .utf8)
    _ = try PluginStorage.install(from: source, root: data)
    return (root, data, source)
  }
  private func file(_ data: URL) -> URL {
    PluginStorage.packageURL(root: data, id: "hook-fixture").appendingPathComponent("hooks/hooks.json")
  }
  private func configuration(_ command: String) -> String {
    JSONValue.object(["hooks": .object(["SessionStart": .array([.object(["hooks": .array([
      .object(["type": .string("command"), "command": .string(command), "statusMessage": .string("Start")])])])])])]).pretty
  }

  @MainActor func testNativeReviewTrustDisablePersistenceAndModifiedDefinitionProtection() async throws {
    let f = try fixture(configuration("printf initial")); defer { try? FileManager.default.removeItem(at: f.root) }
    let executable = try AgentTestExecutable.url(), state = HookSettingsState(root: f.data)
    await state.reload(executable: executable)
    let source = try XCTUnwrap(state.sources.first), hook = try XCTUnwrap(source.hooks.first)
    XCTAssertEqual(hook.trustStatus, "untrusted"); XCTAssertFalse(hook.active)
    XCTAssertEqual(hook.eventName, "session_start"); XCTAssertEqual(hook.eventTitle, "SessionStart")
    state.open(source.id)
    await state.change(sourceID: source.id, expected: [hook], enabled: true, executable: executable)
    XCTAssertNotNil(state.error); XCTAssertTrue(try HookStateStorage.load(root: f.data).isEmpty)
    await state.change(sourceID: source.id, expected: [hook], trust: true, executable: executable)
    let trusted = try XCTUnwrap(state.selectedSource?.hooks.first)
    XCTAssertEqual(trusted.trustStatus, "trusted"); XCTAssertTrue(trusted.active)
    await state.change(sourceID: source.id, expected: [trusted], enabled: false, executable: executable)
    let disabled = try XCTUnwrap(state.selectedSource?.hooks.first)
    XCTAssertFalse(disabled.enabled); XCTAssertEqual(disabled.trustStatus, "trusted")
    await state.change(sourceID: source.id, expected: [disabled], trust: true, executable: executable)
    XCTAssertFalse(try XCTUnwrap(state.selectedSource?.hooks.first).enabled, "Trust must not enable a disabled handler")
    let persisted = HookSettingsState(root: f.data); await persisted.reload(executable: executable)
    XCTAssertEqual(persisted.sources.first?.hooks.first?.trustStatus, "trusted")
    XCTAssertEqual(persisted.sources.first?.hooks.first?.enabled, false)
    try configuration("printf modified").write(to: file(f.data), atomically: true, encoding: .utf8)
    await state.change(sourceID: source.id, expected: [disabled], enabled: true, executable: executable)
    XCTAssertTrue(state.error?.contains("发生变化") == true)
    XCTAssertEqual(try HookStateStorage.load(root: f.data)[source.id]?[hook.key]?.trustedHash, trusted.currentHash)
    await state.reload(executable: executable)
    XCTAssertEqual(state.selectedSource?.id, source.id, "Edits retain the source identity")
    XCTAssertEqual(state.selectedSource?.hooks.first?.trustStatus, "modified")
    XCTAssertFalse(try XCTUnwrap(state.selectedSource?.hooks.first).active)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.data.appendingPathComponent("HookStaging").path).isEmpty)
  }

  @MainActor func testLargeMCPInputIsReviewedIntactAndOnlyItsDefinitionChangeInvalidatesTrust() async throws {
    let text = String(repeating: "世界", count: 20_000)
    let json = JSONValue.object(["hooks": .object(["PreToolUse": .array([.object(["matcher": .string("shell"), "hooks": .array([
      .object(["type": .string("mcp_tool"), "server": .string("policy"), "tool": .string("inspect"), "input": .object(["evidence": .string(text)])]),
      .object(["type": .string("command"), "command": .string("printf second")])])])])])])
    let f = try fixture(json.pretty); defer { try? FileManager.default.removeItem(at: f.root) }
    let executable = try AgentTestExecutable.url(), state = HookSettingsState(root: f.data)
    await state.reload(executable: executable)
    let source = try XCTUnwrap(state.sources.first)
    XCTAssertEqual(source.hooks.count, 2, source.error ?? "")
    XCTAssertEqual(source.hooks.first?.definition["handler"]["input"]["evidence"].text, text)
    state.open(source.id)
    await state.change(sourceID: source.id, expected: source.hooks, trust: true, executable: executable)
    XCTAssertTrue(state.selectedSource?.hooks.allSatisfy { $0.trustStatus == "trusted" } == true)
    try json.pretty.replacingOccurrences(of: "世界", with: "天地").write(to: file(f.data), atomically: true, encoding: .utf8)
    await state.reload(executable: executable)
    XCTAssertEqual(state.selectedSource?.hooks.map(\.trustStatus), ["modified", "trusted"])
  }

  @MainActor func testDisabledAndRemovedPluginsCannotEnterSessionOrAcceptStaleReview() async throws {
    let f = try fixture(configuration("printf disabled")); defer { try? FileManager.default.removeItem(at: f.root) }
    let executable = try AgentTestExecutable.url(), state = HookSettingsState(root: f.data)
    await state.reload(executable: executable)
    let source = try XCTUnwrap(state.sources.first)
    state.open(source.id)
    _ = try PluginStorage.setEnabled(false, id: "hook-fixture", root: f.data)
    await state.change(sourceID: source.id, expected: source.hooks, trust: true, executable: executable)
    XCTAssertEqual(state.selectedSource?.pluginEnabled, false)
    XCTAssertEqual(state.selectedSource?.activeCount, 0)
    XCTAssertTrue(try state.sessionBindings().isEmpty)
    _ = try PluginStorage.remove(id: "hook-fixture", root: f.data)
    await state.change(sourceID: source.id, expected: source.hooks, enabled: true, executable: executable)
    XCTAssertTrue(state.error?.contains("移除") == true)
    await state.reload(executable: executable)
    XCTAssertTrue(state.sources.isEmpty); XCTAssertNil(state.selectedSourceID)
  }

  @MainActor func testInvalidPluginSourceDoesNotHideValidSibling() async throws {
    let f = try fixture(configuration("printf valid")); defer { try? FileManager.default.removeItem(at: f.root) }
    let invalid = f.root.appendingPathComponent("Invalid")
    try FileManager.default.createDirectory(at: invalid.appendingPathComponent(".codex-plugin"), withIntermediateDirectories: true)
    try #"{"id":"invalid-hooks","name":"Invalid","hooks":{"hooks":{"SessionStart":"bad"}}}"#.write(
      to: invalid.appendingPathComponent(".codex-plugin/plugin.json"), atomically: true, encoding: .utf8)
    _ = try PluginStorage.install(from: invalid, root: f.data)
    let state = HookSettingsState(root: f.data); await state.reload(executable: try AgentTestExecutable.url())
    XCTAssertEqual(state.sources.count, 2)
    XCTAssertEqual(state.sources.first { $0.pluginID == "hook-fixture" }?.hooks.count, 1)
    XCTAssertNotNil(state.sources.first { $0.pluginID == "invalid-hooks" }?.error)
    XCTAssertThrowsError(try state.sessionBindings())
  }

  func testStateWritesMergeAndRefuseSymlinkedDecisionOrStagingPaths() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try HookStateStorage.update(root: root, sourceID: "first", changes: ["stop:0:0": .init(enabled: false)])
    try HookStateStorage.update(root: root, sourceID: "second", changes: ["stop:0:0": .init(trustedHash: "hash")])
    try HookStateStorage.update(root: root, sourceID: "first", changes: ["stop:0:0": .init(trustedHash: "new")])
    XCTAssertEqual(try HookStateStorage.load(root: root)["first"]?["stop:0:0"], .init(enabled: false, trustedHash: "new"))
    XCTAssertEqual(try HookStateStorage.load(root: root)["second"]?["stop:0:0"]?.trustedHash, "hash")
    let outside = root.appendingPathComponent("outside.json")
    try "{}".write(to: outside, atomically: true, encoding: .utf8)
    let file = HookStateStorage.url(root: root); try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
    XCTAssertThrowsError(try HookStateStorage.load(root: root))
    XCTAssertThrowsError(try HookStateStorage.update(root: root, sourceID: "first", changes: [:]))
    let staging = root.appendingPathComponent("HookStaging")
    try FileManager.default.createSymbolicLink(at: staging, withDestinationURL: root)
    XCTAssertThrowsError(try HookStaging.stage([], root: root))
    XCTAssertEqual(try String(contentsOf: outside), "{}")
  }

  @MainActor func testReviewModalBlocksSettingsNavigationAndKeyboardCyclesBothDirections() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = WorkspaceStore(dataRoot: root)
    store.hookSettings.selectedSourceID = "fixture"
    XCTAssertTrue(store.hasSettingsConfirmation)
    XCTAssertEqual(HookReviewDialog.next(.trustAll, actions: [.close, .trustAll, .issues], backwards: false), .issues)
    XCTAssertEqual(HookReviewDialog.next(.close, actions: [.close, .trustAll, .issues], backwards: true), .issues)
    XCTAssertEqual(HookReviewDialog.next(.issues, actions: [.close, .trustAll, .issues], backwards: false), .close)
    for (key, flags, expected) in [(UInt16(48), NSEvent.ModifierFlags(), HookReviewKeyboardBridge.Key.next),
      (48, .shift, .previous), (53, [], .cancel), (36, [], .activate)] {
      let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
        timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key))
      XCTAssertEqual(HookReviewKeyboardBridge.key(event), expected)
    }
    store.hookSettings.close(); XCTAssertFalse(store.hasSettingsConfirmation)
  }

  @MainActor func testMultipleFilesGroupByPluginAndBatchTrustIsAtomicWithoutEnablingDisabledHooks() async throws {
    let f = try fixture(configuration("printf one")); defer { try? FileManager.default.removeItem(at: f.root) }
    let package = PluginStorage.packageURL(root: f.data, id: "hook-fixture")
    try configuration("printf two").write(to: package.appendingPathComponent("hooks/two.json"), atomically: true, encoding: .utf8)
    try #"{"id":"hook-fixture","name":"Hook Fixture","hooks":["./hooks/hooks.json","./hooks/two.json"]}"#.write(
      to: package.appendingPathComponent(".codex-plugin/plugin.json"), atomically: true, encoding: .utf8)
    let executable = try AgentTestExecutable.url(), state = HookSettingsState(root: f.data)
    await state.reload(executable: executable)
    let group = try XCTUnwrap(state.groups.first)
    XCTAssertEqual(state.groups.count, 1); XCTAssertEqual(group.sources.count, 2); XCTAssertEqual(group.hooks.count, 2)
    XCTAssertEqual(Set(group.hooks.map(\.key)).count, 1, "Same event indices are independent in separate files")
    XCTAssertEqual(Set(group.hooks.map(\.id)).count, 2)
    let first = group.hooks[0]
    try HookStateStorage.update(root: f.data, sourceID: first.sourceId, changes: [first.key: .init(enabled: false)])
    state.open(group.id)
    await state.change(sourceID: group.id, expected: group.hooks, trust: true, executable: executable)
    XCTAssertNil(state.error)
    let trusted = try XCTUnwrap(state.selectedGroup)
    XCTAssertEqual(trusted.hooks.map(\.trustStatus), ["trusted", "trusted"])
    XCTAssertEqual(trusted.hooks.map(\.enabled), [false, true])
    let decisions = try HookStateStorage.load(root: f.data)
    try configuration("printf changed").write(to: package.appendingPathComponent("hooks/two.json"), atomically: true, encoding: .utf8)
    await state.change(sourceID: group.id, expected: trusted.hooks, enabled: true, executable: executable)
    XCTAssertTrue(state.error?.contains("发生变化") == true)
    XCTAssertEqual(try HookStateStorage.load(root: f.data), decisions, "A stale batch must not partially mutate any source")
  }

  @MainActor func testHookReviewRendersWithinOwningWindowAtWideAndNarrowSizes() async throws {
    let f = try fixture(configuration("printf review")); defer { try? FileManager.default.removeItem(at: f.root) }
    let store = WorkspaceStore(dataRoot: f.data, agentExecutable: try AgentTestExecutable.url())
    await store.hookSettings.reload(executable: store.executable)
    let group = try XCTUnwrap(store.hookSettings.groups.first); store.hookSettings.open(group.id)
    _ = NSApplication.shared
    for size in [NSSize(width: 1000, height: 760), NSSize(width: 420, height: 480)] {
      let window = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.identifier = .init("hook-test-owner")
      let host = NSHostingView(rootView: HookReviewDialog(store: store, sourceID: group.id))
      window.contentView = host
      try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
      XCTAssertTrue(host.bounds.width.isFinite); XCTAssertEqual(window.identifier?.rawValue, "hook-test-owner")
      XCTAssertNil(window.attachedSheet)
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      if let directory = ProcessInfo.processInfo.environment["SHIPIOS_HOOK_RENDER_DIRECTORY"] {
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
          to: URL(fileURLWithPath: directory).appendingPathComponent("hooks-\(Int(size.width)).png"), options: .atomic)
      }
      window.close()
    }
  }

  @MainActor func testStoreTurnsUseTrustedHooksRefreshDecisionsAndResumeSameTask() async throws {
    let markerRoot = FileManager.default.temporaryDirectory.appendingPathComponent("hook-marker-\(UUID())")
    try FileManager.default.createDirectory(at: markerRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: markerRoot) }
    let marker = markerRoot.appendingPathComponent("ran")
    let command = "printf 'start\\n' >> '\(marker.path)'; printf 'NATIVE-HOOK-CONTEXT\\n'"
    let f = try fixture(configuration(command)); defer { try? FileManager.default.removeItem(at: f.root) }
    let server = try GitGenerationFixture(root: f.root); defer { server.stop() }
    let store = WorkspaceStore(dataRoot: f.data, agentExecutable: try AgentTestExecutable.url())
    await store.restore()
    let project = f.root.appendingPathComponent("Project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    await store.open(project); try store.saveModelConfiguration(server.config)
    store.notificationPreferences = .init(timing: .never)
    store.draft = "First untrusted turn"; await store.sendDraft()
    let task = try XCTUnwrap(store.selectedTask), first = try XCTUnwrap(task.runIDs.first)
    await store.modelTask(runID: first)?.value
    XCTAssertEqual(store.library.chatRuns.first { $0.id == first }?.status, "succeeded")
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    await store.hookSettings.reload(executable: store.executable)
    let source = try XCTUnwrap(store.hookSettings.sources.first); store.hookSettings.open(source.id)
    await store.hookSettings.change(sourceID: source.id, expected: source.hooks, trust: true, executable: store.executable)
    store.hookSettings.close()
    let trustedStarted = await store.startChat("Trusted follow-up", taskID: task.id)
    let trustedRun = try XCTUnwrap(trustedStarted)
    await store.modelTask(runID: trustedRun)?.value
    XCTAssertEqual(store.library.chatRuns.first { $0.id == trustedRun }?.status, "succeeded")
    XCTAssertEqual(try String(contentsOf: marker), "start\n")
    let requests = try server.records()
    XCTAssertEqual(requests.count, 2)
    XCTAssertTrue(requests.last?["body"].pretty.contains("NATIVE-HOOK-CONTEXT") == true)
    XCTAssertFalse(requests.first?["body"].pretty.contains("NATIVE-HOOK-CONTEXT") == true)
    let thread = try XCTUnwrap(store.library.tasks.first { $0.id == task.id }?.codexThreadID)
    store.hookSettings.open(source.id)
    let hook = try XCTUnwrap(store.hookSettings.selectedSource?.hooks.first)
    await store.hookSettings.change(sourceID: source.id, expected: [hook], enabled: false, executable: store.executable)
    store.hookSettings.close()
    let disabledStarted = await store.startChat("Disabled follow-up", taskID: task.id)
    let disabledRun = try XCTUnwrap(disabledStarted)
    await store.modelTask(runID: disabledRun)?.value
    XCTAssertEqual(store.library.chatRuns.first { $0.id == disabledRun }?.status, "succeeded")
    XCTAssertEqual(try String(contentsOf: marker), "start\n")
    XCTAssertEqual(store.library.tasks.first { $0.id == task.id }?.codexThreadID, thread)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.data.appendingPathComponent("HookStaging").path).isEmpty)
    await store.shutdown()
  }
}
