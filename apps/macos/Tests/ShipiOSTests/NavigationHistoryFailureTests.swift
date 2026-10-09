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
        with (base / 'requests').open('a') as log:
            log.write(json.dumps({'project': os.path.basename(project), 'method': method, 'params': request.get('params', {})}) + '\n')
        if os.path.basename(project) == 'Source' and method == 'initialize' and (base / 'source-gate').exists():
            (base / 'source-reached').touch()
            while (base / 'source-gate').exists(): time.sleep(0.01)
        if os.path.basename(project) == 'Target' and (base / 'gate').exists() and method == ((base / 'gate').read_text() or 'initialize'):
            (base / 'reached').write_text(method)
            while (base / 'gate').exists(): time.sleep(0.01)
            if (base / 'run-state').exists() and method.startswith('environment.'):
                print(json.dumps({'jsonrpc': '2.0', 'method': 'run.event', 'params': {
                    'runId': 'remote-run', 'sequence': 1, 'timestamp': 2000,
                    'kind': 'run.finished', 'payload': {}}}), flush=True)
        response = {'jsonrpc': '2.0', 'id': request['id']}
        if os.path.basename(project) == 'Target' and (base / 'fail').exists() and (base / 'fail').read_text() == method:
            response['error'] = {'code': -32000, 'message': 'fixture scope preparation failed'}
        else:
            values = {'initialize': {'protocolVersion': 1},
                      'project.inspect': {'root': project, 'containers': [], 'swiftPackages': [], 'diagnostics': [], 'scanTruncated': False},
                      'config.get': {}, 'run.list': [], 'environment.list': [], 'run.events': {'events': []}}
            if os.path.basename(project) == 'Target' and (base / 'run-state').exists():
                status = (base / 'run-state').read_text()
                values['run.list'] = [{'id': 'remote-run', 'kind': 'build', 'project': project,
                    'status': status, 'createdAt': 1000, 'updatedAt': 1000 if status == 'running' else 2000,
                    'request': {}, 'result': None}]
                values['run.get'] = values['run.list'][0]
            if (base / 'shared-mode').exists():
                mode = (base / 'shared-mode').read_text()
                values['environment.list'] = [{'id': 'environment.toml', 'fileName': 'environment.toml', 'name': 'Shared', 'error': None, 'inherited': False, 'sourceFolder': project}]
                values['environment.load'] = {'exists': mode != 'missing', 'revision': 'revision-' + os.path.basename(project),
                    'error': 'invalid environment' if mode == 'parse' else None,
                    'config': {'name': os.path.basename(project) + ' environment',
                        'setup': {'script': 'echo setup', 'darwin': {'script': 'echo mac'}},
                        'cleanup': {'script': 'echo cleanup'},
                        'actions': [{'name': 'Test', 'icon': 'hammer', 'command': 'echo test', 'platform': 'macos'}]}}
            if (base / 'detail-mode').exists():
                mode = (base / 'detail-mode').read_text()
                run = request.get('params', {}).get('runId', '')
                values['run.events'] = {'events': [{'runId': run, 'sequence': 1, 'timestamp': 0, 'kind': 'step.started', 'payload': {'text': 'old result'}}]}
                values['artifact.get'] = {'text': 'old log', 'truncated': False}
            response['result'] = values.get(method, {})
            if (base / 'detail-mode').exists() and (base / 'detail-mode').read_text() == 'error' and method == 'run.events':
                response.pop('result')
                response['error'] = {'code': -32000, 'message': 'old detail failure'}
        if os.path.basename(project) == 'Target' and method == 'run.list' and (base / 'snapshot-late').exists():
            mode = (base / 'snapshot-late').read_text()
            (base / 'snapshot-late').unlink()
            (base / 'run-state').write_text('succeeded')
            notification = {'jsonrpc': '2.0', 'method': 'events.gap', 'params': {}}
            if mode == 'event':
                notification = {'jsonrpc': '2.0', 'method': 'run.event', 'params': {
                    'runId': 'remote-run', 'sequence': 2, 'timestamp': 2000, 'kind': 'run.finished', 'payload': {}}}
            # The snapshot was captured above. Deliver its newer notification in
            # the same pipe write, before the waiting request can resume.
            print(json.dumps(notification) + '\n' + json.dumps(response), flush=True)
        else:
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
      try? FileManager.default.removeItem(at: base.appendingPathComponent("source-gate"))
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

  private func environmentTarget(_ f: Fixture, draft: Bool = false, mode: String = "valid") throws -> TaskLocation {
    try Data(mode.utf8).write(to: f.source.deletingLastPathComponent().appendingPathComponent("shared-mode"))
    f.store.environmentName = "source custom environment"; f.store.worktreeSetupScript = "echo source"
    f.store.environmentFileName = "source.toml"
    f.store.environmentLoadedState = f.store.currentEnvironmentFormState
    let owner = "new:\(f.target.path):link:\(UUID().uuidString)"
    f.store.library.drafts[owner] = "linked target"
    return .init(project: f.target.path, run: draft ? nil : "target", draftOwner: draft ? owner : nil)
  }

  private func gate(_ f: Fixture, method: String) throws { try Data(method.utf8).write(to: f.gate) }

  private func checkEnvironmentCandidate(_ method: String) async throws {
    let f = try await fixture(stage: "none"), store = f.store
    let target = try environmentTarget(f), origin = store.currentTaskLocation, form = store.currentEnvironmentFormState
    let config = store.config, layout = store.workspaceTabLayoutSnapshot
    store.navigationBack = [target]; store.navigationForward = []
    try gate(f, method: method)
    let navigation = Task { await store.navigate(back: true) }; try await waitForGate(f)
    XCTAssertEqual(store.currentTaskLocation, origin); XCTAssertEqual(store.project?.path, f.source.path)
    XCTAssertEqual(store.workspace.root?.path, f.source.path); XCTAssertEqual(store.draft, "source draft")
    XCTAssertEqual(store.currentEnvironmentFormState, form); XCTAssertEqual(store.config, config)
    XCTAssertEqual(store.workspaceTabLayoutSnapshot, layout); XCTAssertEqual(store.workspace.fileText, "source preview")
    XCTAssertEqual(store.navigationBack, [target]); XCTAssertTrue(store.navigationForward.isEmpty)
    try FileManager.default.removeItem(at: f.gate); await navigation.value
    XCTAssertEqual(store.currentTaskLocation, target); XCTAssertTrue(store.navigationBack.isEmpty)
    XCTAssertEqual(store.navigationForward, [origin]); XCTAssertEqual(store.environmentName, "Target environment")
    XCTAssertEqual(store.worktreeSetupScript, "echo setup"); XCTAssertEqual(store.setupPlatformScripts.darwin, "echo mac")
    XCTAssertEqual(store.worktreeCleanupScript, "echo cleanup"); XCTAssertEqual(store.environmentActions.first?.script, "echo test")
    XCTAssertEqual(store.environmentRevision, "revision-Target"); XCTAssertTrue(store.environmentExists)
    XCTAssertEqual(store.environmentLoadedState, store.currentEnvironmentFormState)
  }

  func testEnvironmentListDoesNotExposePartialTargetScope() async throws { try await checkEnvironmentCandidate("environment.list") }
  func testEnvironmentLoadDoesNotExposePartialTargetScope() async throws { try await checkEnvironmentCandidate("environment.load") }

  func testRunCompletionDuringEnvironmentPreparationAppearsOnCommittedPage() async throws {
    for method in ["environment.list", "environment.load"] {
      for history in [false, true] {
        let f = try await fixture(stage: "none"), store = f.store
        let target = try environmentTarget(f), origin = store.currentTaskLocation
        store.library.tasks[1].runIDs = ["remote-run"]
        let state = f.source.deletingLastPathComponent().appendingPathComponent("run-state")
        try Data("running".utf8).write(to: state)
        store.navigationBack = [target]; store.navigationForward = []
        try gate(f, method: method)
        let navigation = Task {
          if history { await store.navigate(back: true) }
          else { await store.open(f.target, loadsDetails: false) }
        }
        try await waitForGate(f)
        XCTAssertEqual(store.currentTaskLocation, origin)
        try Data("succeeded".utf8).write(to: state, options: .atomic)
        try FileManager.default.removeItem(at: f.gate); await navigation.value
        let run = try XCTUnwrap(store.runs.first { $0.id == "remote-run" })
        XCTAssertEqual(run.status, "succeeded", "\(method), history=\(history)")
        XCTAssertEqual(run.updatedAt, 2000); XCTAssertNil(store.activeLocalRun)
        XCTAssertTrue(store.connected); XCTAssertEqual(store.project?.path, f.target.path)
        if history {
          XCTAssertTrue(store.navigationBack.isEmpty); XCTAssertEqual(store.navigationForward, [origin])
        }
      }
    }
  }

  func testBackgroundModelChangesDuringEnvironmentPreparationUseLatestLocalSnapshot() async throws {
    for method in ["environment.list", "environment.load"] {
      let f = try await fixture(stage: "none"), store = f.store
      let target = try environmentTarget(f), origin = store.currentTaskLocation
      func modelRun(_ id: String, status: String) -> AgentRun {
        .init(id: id, kind: "chat", project: f.target.path, status: status,
          createdAt: 1000, updatedAt: status == "running" ? 1000 : 2000,
          request: .object([:]), result: nil)
      }
      store.library.chatRuns = [modelRun("model-run", status: "running")]
      store.navigationBack = [target]; store.navigationForward = []
      try gate(f, method: method)
      let navigation = Task { await store.navigate(back: true) }; try await waitForGate(f)
      XCTAssertEqual(store.currentTaskLocation, origin)
      store.library.chatRuns = [modelRun("model-run", status: "succeeded"), modelRun("new-model-run", status: "succeeded")]
      store.library.forkRuns = [modelRun("new-fork-run", status: "succeeded")]
      try FileManager.default.removeItem(at: f.gate); await navigation.value
      XCTAssertEqual(Set(store.runs.map(\.id)), ["model-run", "new-model-run", "new-fork-run"])
      XCTAssertTrue(store.runs.allSatisfy { $0.status == "succeeded" && $0.updatedAt == 2000 })
      XCTAssertEqual(store.runs.count, 3); XCTAssertEqual(store.currentTaskLocation, target)
      XCTAssertTrue(store.navigationBack.isEmpty); XCTAssertEqual(store.navigationForward, [origin])
      for run in store.runs { XCTAssertNotNil(store.library.task(containing: run.id)) }
    }
  }

  func testNotificationsNewerThanFinalRunSnapshotAreReplayedAfterScopeCommit() async throws {
    for mode in ["event", "gap"] {
      let f = try await fixture(stage: "none"), store = f.store
      let target = try environmentTarget(f)
      store.library.tasks[1].runIDs = ["remote-run"]
      let base = f.source.deletingLastPathComponent()
      try Data("running".utf8).write(to: base.appendingPathComponent("run-state"))
      try Data(mode.utf8).write(to: base.appendingPathComponent("snapshot-late"))
      store.navigationBack = [target]; store.navigationForward = []
      await store.navigate(back: true)
      for _ in 0..<120 where store.runs.first(where: { $0.id == "remote-run" })?.isActive != false {
        try await Task.sleep(for: .milliseconds(25))
      }
      let run = try XCTUnwrap(store.runs.first { $0.id == "remote-run" })
      XCTAssertEqual(run.status, "succeeded", mode); XCTAssertEqual(run.updatedAt, 2000)
      XCTAssertNil(store.activeLocalRun); XCTAssertNil(store.error)
      XCTAssertTrue(store.connected); XCTAssertEqual(store.project?.path, f.target.path)
      XCTAssertTrue(store.navigationBack.isEmpty)
    }
  }

  func testFinalRunSnapshotCancellationAndChangedHistoryKeepSourcePage() async throws {
    for cancel in [false, true] {
      let f = try await fixture(stage: "none"), store = f.store
      let target = try environmentTarget(f), origin = store.currentTaskLocation
      let form = store.currentEnvironmentFormState
      store.navigationBack = [target]; store.navigationForward = []
      try gate(f, method: "run.list")
      let navigation = Task { await store.navigate(back: true) }; try await waitForGate(f)
      if cancel { navigation.cancel() }
      else { store.recordNavigation(.init(project: f.source.path, run: "new action")) }
      let back = store.navigationBack, forward = store.navigationForward
      try FileManager.default.removeItem(at: f.gate); await navigation.value
      XCTAssertEqual(store.currentTaskLocation, origin); XCTAssertEqual(store.project?.path, f.source.path)
      XCTAssertEqual(store.currentEnvironmentFormState, form); XCTAssertEqual(store.draft, "source draft")
      XCTAssertEqual(store.navigationBack, back); XCTAssertEqual(store.navigationForward, forward)
      XCTAssertFalse(store.connected); XCTAssertFalse(store.busy); XCTAssertFalse(store.navigatingWorkspaceHistory)
    }
  }

  func testOldReloadReplyAndFailureCannotMutateScopeBeingPrepared() async throws {
    for failure in [false, true] {
      let f = try await fixture(stage: "none"), store = f.store
      let base = f.source.deletingLastPathComponent()
      try Data("succeeded".utf8).write(to: base.appendingPathComponent("run-state"))
      await store.open(f.target, loadsDetails: false)
      let previousRuns = store.runs
      try Data("running".utf8).write(to: base.appendingPathComponent("run-state"))
      try gate(f, method: "run.list")
      let reload = Task { await store.reload() }; try await waitForGate(f)
      if failure { try Data("run.list".utf8).write(to: f.failure) }
      let sourceGate = base.appendingPathComponent("source-gate"), sourceReached = base.appendingPathComponent("source-reached")
      try Data().write(to: sourceGate)
      let navigation = Task { await store.open(f.source, loadsDetails: false) }
      for _ in 0..<120 where !store.preparingProjectScope { try await Task.sleep(for: .milliseconds(25)) }
      XCTAssertTrue(store.preparingProjectScope)
      try FileManager.default.removeItem(at: f.gate)
      await reload.value
      for _ in 0..<120 where !FileManager.default.fileExists(atPath: sourceReached.path) {
        try await Task.sleep(for: .milliseconds(25))
      }
      XCTAssertTrue(FileManager.default.fileExists(atPath: sourceReached.path))
      XCTAssertEqual(store.runs, previousRuns); XCTAssertNil(store.error)
      try FileManager.default.removeItem(at: sourceGate); await navigation.value
      XCTAssertEqual(store.project?.path, f.source.path); XCTAssertTrue(store.runs.isEmpty)
      XCTAssertNil(store.error); XCTAssertTrue(store.connected)
    }
  }

  func testReplayedRunReplyCannotOverwriteNextScopePreparation() async throws {
    let f = try await fixture(stage: "none"), store = f.store
    let target = try environmentTarget(f), base = f.source.deletingLastPathComponent()
    store.library.tasks[1].runIDs = ["remote-run"]
    // A terminal snapshot permits navigation. An active local build deliberately
    // blocks switching projects, independently of a pending notification read.
    try Data("succeeded".utf8).write(to: base.appendingPathComponent("run-state"))
    try Data("event".utf8).write(to: base.appendingPathComponent("snapshot-late"))
    try gate(f, method: "run.get")
    store.navigationBack = [target]; store.navigationForward = []
    await store.navigate(back: true); try await waitForGate(f)
    let previousRuns = store.runs
    let sourceGate = base.appendingPathComponent("source-gate"), sourceReached = base.appendingPathComponent("source-reached")
    try Data().write(to: sourceGate)
    let navigation = Task { await store.navigate(back: false) }
    for _ in 0..<120 where !store.preparingProjectScope { try await Task.sleep(for: .milliseconds(25)) }
    XCTAssertTrue(store.preparingProjectScope)
    try FileManager.default.removeItem(at: f.gate)
    for _ in 0..<120 where !FileManager.default.fileExists(atPath: sourceReached.path) {
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: sourceReached.path))
    XCTAssertEqual(store.runs, previousRuns); XCTAssertNil(store.error)
    try FileManager.default.removeItem(at: sourceGate); await navigation.value
    XCTAssertEqual(store.project?.path, f.source.path); XCTAssertTrue(store.runs.isEmpty)
    XCTAssertEqual(store.draft, "source draft"); XCTAssertNil(store.error); XCTAssertTrue(store.connected)
    XCTAssertEqual(store.navigationBack, [target]); XCTAssertTrue(store.navigationForward.isEmpty)
  }

  func testCancellationDuringEnvironmentPreparationKeepsSourceDraftAndHistory() async throws {
    for method in ["environment.list", "environment.load"] {
      for draft in [false, true] {
        let f = try await fixture(stage: "none"), store = f.store
        let target = try environmentTarget(f, draft: draft), origin = store.currentTaskLocation, form = store.currentEnvironmentFormState
        store.navigationBack = [target]; store.navigationForward = [origin]
        try gate(f, method: method)
        let navigation = Task { await store.navigate(back: true) }; try await waitForGate(f)
        navigation.cancel(); try FileManager.default.removeItem(at: f.gate); await navigation.value
        XCTAssertEqual(store.currentTaskLocation, origin); XCTAssertEqual(store.draft, "source draft")
        XCTAssertEqual(store.currentEnvironmentFormState, form); XCTAssertEqual(store.workspace.fileText, "source preview")
        XCTAssertEqual(store.navigationBack, [target]); XCTAssertEqual(store.navigationForward, [origin])
        XCTAssertFalse(store.connected); XCTAssertFalse(store.navigatingWorkspaceHistory)
      }
    }
  }

  func testChangedHistoryDuringEnvironmentPreparationCannotApplyTarget() async throws {
    for method in ["environment.list", "environment.load"] {
      let f = try await fixture(stage: "none"), store = f.store
      let target = try environmentTarget(f), origin = store.currentTaskLocation
      store.navigationBack = [target]; try gate(f, method: method)
      let navigation = Task { await store.navigate(back: true) }; try await waitForGate(f)
      store.recordNavigation(.init(project: f.source.path, run: "new action"))
      let back = store.navigationBack, forward = store.navigationForward
      try FileManager.default.removeItem(at: f.gate); await navigation.value
      XCTAssertEqual(store.currentTaskLocation, origin); XCTAssertEqual(store.draft, "source draft")
      XCTAssertEqual(store.navigationBack, back); XCTAssertEqual(store.navigationForward, forward)
    }
  }

  private func prepareDetailHistory(_ f: Fixture, artifact: Bool = false) -> (TaskLocation, TaskLocation) {
    let store = f.store
    store.library.tasks[1].runIDs = ["target-run"]
    store.library.tasks.append(.init(id: "remembered", project: f.target.path, title: "Remembered", runIDs: ["remembered-run"]))
    store.library.projectSelections[f.target.path] = "remembered-run"
    store.library.forkRuns = ["remembered-run", "target-run"].map {
      .init(id: $0, kind: "build", project: f.target.path, status: "succeeded", createdAt: 0, updatedAt: 0, request: .object([:]), result: artifact ? .object(["artifactDirectory": .string("fixture")]) : nil)
    }
    let target = TaskLocation(project: f.target.path, run: "target-run"), origin = store.currentTaskLocation
    store.navigationBack = [target]; store.navigationForward = []
    return (target, origin)
  }

  private func requestedDetailRuns(_ f: Fixture) throws -> [String] {
    try String(contentsOf: f.source.deletingLastPathComponent().appendingPathComponent("requests"), encoding: .utf8)
      .split(separator: "\n").compactMap { line in
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          object["project"] as? String == "Target", object["method"] as? String == "run.events",
          let params = object["params"] as? [String: Any] else { return nil }
        return params["runId"] as? String
      }
  }

  func testHistoryCommitsRequestedRunBeforeItsDetailReply() async throws {
    let f = try await fixture(stage: "none"), store = f.store
    let (target, origin) = prepareDetailHistory(f); try gate(f, method: "run.events")
    let navigation = Task { await store.navigate(back: true) }; try await waitForGate(f)
    XCTAssertEqual(store.currentTaskLocation, target); XCTAssertTrue(store.navigationBack.isEmpty)
    XCTAssertEqual(store.navigationForward, [origin]); XCTAssertFalse(store.navigatingWorkspaceHistory)
    XCTAssertTrue(store.commandEnabled("forward")); XCTAssertEqual(try requestedDetailRuns(f), ["target-run"])
    try FileManager.default.removeItem(at: f.gate); await navigation.value
    XCTAssertEqual(store.currentTaskLocation, target); XCTAssertEqual(try requestedDetailRuns(f), ["target-run"])
  }

  func testNewHistoryNavigationDuringDetailLoadRetainsNewPageAndStacks() async throws {
    let f = try await fixture(stage: "none"), store = f.store
    let (target, origin) = prepareDetailHistory(f); try gate(f, method: "run.events")
    let navigation = Task { await store.navigate(back: true) }; try await waitForGate(f)
    await store.navigate(back: false)
    try FileManager.default.removeItem(at: f.gate); await navigation.value
    XCTAssertEqual(store.currentTaskLocation, origin); XCTAssertEqual(store.draft, "source draft")
    XCTAssertEqual(store.navigationBack, [target]); XCTAssertTrue(store.navigationForward.isEmpty)
    XCTAssertEqual(store.workspace.root?.path, f.source.path); XCTAssertTrue(store.logText.isEmpty)
  }

  func testDirectProjectOpenStillLoadsItsRememberedRun() async throws {
    let f = try await fixture(stage: "none"), store = f.store
    _ = prepareDetailHistory(f)
    await store.open(f.target)
    XCTAssertEqual(store.selection, "remembered-run")
    XCTAssertEqual(try requestedDetailRuns(f), ["remembered-run"])
  }

  func testEnvironmentReadFailuresRemainVisibleAfterSuccessfulHistorySelection() async throws {
    for method in ["environment.list", "environment.load"] {
      let f = try await fixture(stage: method), store = f.store
      let target = try environmentTarget(f), origin = store.currentTaskLocation
      store.navigationBack = [target]; await store.navigate(back: true)
      XCTAssertEqual(store.currentTaskLocation, target); XCTAssertTrue(store.connected)
      XCTAssertTrue(store.navigationBack.isEmpty); XCTAssertEqual(store.navigationForward, [origin])
      XCTAssertTrue(store.environmentStatus.contains("失败")); XCTAssertFalse(store.environmentExists)
    }
  }

  func testMissingAndMalformedEnvironmentKeepTheirExistingFormSemantics() async throws {
    for mode in ["missing", "parse"] {
      let f = try await fixture(stage: "none"), store = f.store
      let target = try environmentTarget(f, mode: mode)
      store.navigationBack = [target]; await store.navigate(back: true)
      XCTAssertEqual(store.currentTaskLocation, target); XCTAssertTrue(store.connected)
      XCTAssertEqual(store.environmentExists, mode == "parse")
      XCTAssertEqual(store.environmentName, mode == "parse" ? "environment" : "Target")
      XCTAssertEqual(store.worktreeSetupScript, ""); XCTAssertTrue(store.environmentActions.isEmpty)
      XCTAssertEqual(store.environmentLoadedState, store.currentEnvironmentFormState)
    }
  }

  func testOldDetailReplyAndErrorCannotWriteIntoAnotherSelection() async throws {
    for mode in ["events", "error"] {
      let f = try await fixture(stage: "none"), store = f.store
      _ = prepareDetailHistory(f)
      await store.open(f.target, loadsDetails: false); store.selection = "target-run"
      try Data(mode.utf8).write(to: f.source.deletingLastPathComponent().appendingPathComponent("detail-mode"))
      try gate(f, method: "run.events")
      let details = Task { await store.loadDetails() }; try await waitForGate(f)
      store.applyTaskSelection(try XCTUnwrap(store.library.tasks.first { $0.id == "remembered" }))
      store.logText = "new page log"
      try FileManager.default.removeItem(at: f.gate); await details.value
      XCTAssertEqual(store.selection, "remembered-run"); XCTAssertTrue(store.events.isEmpty)
      XCTAssertEqual(store.logText, "new page log")
    }
  }

  func testOldArtifactReplyCannotOverwriteNewSelectionLog() async throws {
    let f = try await fixture(stage: "none"), store = f.store
    _ = prepareDetailHistory(f, artifact: true)
    await store.open(f.target, loadsDetails: false); store.selection = "target-run"
    try Data("events".utf8).write(to: f.source.deletingLastPathComponent().appendingPathComponent("detail-mode"))
    try gate(f, method: "artifact.get")
    let details = Task { await store.loadDetails() }; try await waitForGate(f)
    store.applyTaskSelection(try XCTUnwrap(store.library.tasks.first { $0.id == "remembered" }))
    store.logText = "new page log"
    try FileManager.default.removeItem(at: f.gate); await details.value
    XCTAssertEqual(store.selection, "remembered-run"); XCTAssertEqual(store.logText, "new page log")
  }
}
