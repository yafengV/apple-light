import XCTest
@testable import ShipiOS

@MainActor final class ProjectScopeFailureTests: XCTestCase {
  private func checkFailure(at method: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("scope-failure-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source").resolvingSymlinksInPath().standardizedFileURL
    let target = root.appendingPathComponent(method).resolvingSymlinksInPath().standardizedFileURL
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let executable = root.appendingPathComponent("fixture-agent")
    let script = #"""
      #!/usr/bin/python3
      import json, os, sys
      project = sys.argv[sys.argv.index('--project') + 1]
      stage = os.path.basename(project)
      for line in sys.stdin:
          request = json.loads(line)
          method = request['method']
          response = {'jsonrpc': '2.0', 'id': request['id']}
          if method == stage:
              response['error'] = {'code': -32000, 'message': 'fixture preparation failed'}
          else:
              values = {
                  'initialize': {'protocolVersion': 1},
                  'project.inspect': {'root': project, 'containers': [], 'swiftPackages': [],
                                      'diagnostics': [], 'scanTruncated': False},
                  'config.get': {'fixture': project}, 'run.list': [], 'environment.list': []
              }
              response['result'] = values.get(method, {})
          print(json.dumps(response), flush=True)
      """#
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("data"), agentExecutable: executable)
    await store.restore()
    await store.open(source)
    XCTAssertTrue(store.connected)
    store.library.tasks = [WorkspaceTask(id: "source", project: source.path, title: "Source", runIDs: ["source-run"]),
      WorkspaceTask(id: "target", project: target.path, title: "Target", runIDs: ["target-run"])]
    store.selectTask(store.library.tasks[0])
    store.draft = "keep source draft"
    store.library.unreadTasks = ["target"]
    store.showingInspector = true
    store.showingTerminal = true
    store.workspace.fileText = "keep preview"
    store.environmentName = "keep source environment"
    store.navigationForward = [.init(project: source.path, run: "other")]
    let back = store.navigationBack, forward = store.navigationForward
    let owner = store.workspaceLayoutActiveOwner
    let config = store.config
    store.toggleActivity()

    let opened = await store.openActivityTask("target")
    XCTAssertFalse(opened)
    XCTAssertEqual(store.project?.path, source.path)
    XCTAssertEqual(store.selectedTask?.id, "source")
    XCTAssertEqual(store.draft, "keep source draft")
    XCTAssertEqual(store.workspace.fileText, "keep preview")
    XCTAssertEqual(store.workspace.root?.path, source.path)
    XCTAssertEqual(store.environmentName, "keep source environment")
    XCTAssertEqual(store.config, config)
    XCTAssertEqual(store.workspaceLayoutActiveOwner, owner)
    XCTAssertTrue(store.showingInspector)
    XCTAssertTrue(store.showingTerminal)
    XCTAssertEqual(store.navigationBack, back)
    XCTAssertEqual(store.navigationForward, forward)
    XCTAssertTrue(store.library.unreadTasks.contains("target"))
    XCTAssertFalse(store.connected, "The old local Agent was stopped; do not pretend it is still connected")
    XCTAssertNotNil(store.activityError)
    XCTAssertFalse(store.busy)
    XCTAssertNil(store.activityOpeningTaskID)

    // Retry must reconnect the displayed project and preserve its task draft.
    await store.open(source)
    XCTAssertTrue(store.connected)
    XCTAssertEqual(store.selectedTask?.id, "source")
    XCTAssertEqual(store.draft, "keep source draft")
    await store.shutdown()
  }

  func testInitializeFailurePreservesDisplayedWorkspace() async throws { try await checkFailure(at: "initialize") }
  func testInspectionFailurePreservesDisplayedWorkspace() async throws { try await checkFailure(at: "project.inspect") }
  func testConfigFailurePreservesDisplayedWorkspace() async throws { try await checkFailure(at: "config.get") }
  func testRunListFailurePreservesDisplayedWorkspace() async throws { try await checkFailure(at: "run.list") }

  private func checkAbandonedScope(fails: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("abandoned-scope-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.resolvingSymlinksInPath().appendingPathComponent("source")
    let target = root.resolvingSymlinksInPath().appendingPathComponent("target")
    for folder in [source, target] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    let executable = root.appendingPathComponent("fixture-agent")
    let script = #"""
      #!/usr/bin/python3
      import json, os, sys, time
      root = os.path.dirname(os.path.abspath(__file__))
      project = sys.argv[sys.argv.index('--project') + 1]
      for line in sys.stdin:
          request = json.loads(line)
          method = request['method']
          response = {'jsonrpc': '2.0', 'id': request['id']}
          if os.path.basename(project) == 'target' and method == 'project.inspect':
              open(os.path.join(root, 'ready'), 'w').close()
              deadline = time.monotonic() + 5
              while not os.path.exists(os.path.join(root, 'release')) and time.monotonic() < deadline:
                  time.sleep(0.01)
              if os.path.exists(os.path.join(root, 'fail')):
                  response['error'] = {'code': -32000, 'message': 'late fixture failure'}
          if 'error' not in response:
              values = {'initialize': {'protocolVersion': 1},
                        'project.inspect': {'root': project, 'containers': [], 'swiftPackages': [],
                                            'diagnostics': [], 'scanTruncated': False},
                        'config.get': {}, 'run.list': [], 'environment.list': []}
              response['result'] = values.get(method, {})
          print(json.dumps(response), flush=True)
      """#
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    if fails { try Data().write(to: root.appendingPathComponent("fail")) }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("data"), agentExecutable: executable)
    await store.restore()
    await store.open(source)
    store.library.tasks = [.init(id: "source", project: source.path, title: "Source", runIDs: [])]
    store.selectTask(store.library.tasks[0])
    store.draft = "original source draft"
    store.workspace.fileText = "source preview"
    var valid = true
    let opening = Task { await store.openTaskScope(target.path, stillValid: { valid }) }
    defer { opening.cancel() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path) {
      guard ContinuousClock.now < deadline else { throw AgentFailure(message: "Delayed scope did not start") }
      try await Task.sleep(for: .milliseconds(10))
    }
    valid = false
    store.destination = .projects
    store.draft = "newer source draft"
    try Data().write(to: root.appendingPathComponent("release"))
    let opened = await opening.value
    XCTAssertFalse(opened)
    XCTAssertEqual(store.project?.path, source.path)
    XCTAssertEqual(store.selectedTask?.id, "source")
    XCTAssertEqual(store.destination, .projects)
    XCTAssertEqual(store.draft, "newer source draft")
    XCTAssertEqual(store.workspace.fileText, "source preview")
    XCTAssertFalse(store.busy)
    XCTAssertFalse(store.connected)
    XCTAssertNil(store.error)
    XCTAssertNil(store.projectRecoveryPath)
    await store.open(source)
    XCTAssertTrue(store.connected)
    XCTAssertEqual(store.draft, "newer source draft")
    await store.shutdown()
  }

  func testAbandonedSuccessDoesNotPublishOldScopeOrReplaceNewerPageAndDraft() async throws {
    try await checkAbandonedScope(fails: false)
  }

  func testAbandonedFailureDoesNotPublishOldErrorOrRetryTarget() async throws {
    try await checkAbandonedScope(fails: true)
  }
}
