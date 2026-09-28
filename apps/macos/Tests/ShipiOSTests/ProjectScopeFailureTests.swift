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
}
