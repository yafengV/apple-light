import XCTest
@testable import ShipiOS

@MainActor final class SidebarForkScopeTests: XCTestCase {
  private func checkOpen(failing: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fork-scope-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source").resolvingSymlinksInPath().standardizedFileURL
    let target = root.appendingPathComponent("target").resolvingSymlinksInPath().standardizedFileURL
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let failureMarker = target.appendingPathComponent("fail")
    if failing { try Data().write(to: failureMarker) }
    let executable = root.appendingPathComponent("agent-fixture")
    let script = #"""
      #!/usr/bin/python3
      import json, os, sys
      project = sys.argv[sys.argv.index('--project') + 1]
      for line in sys.stdin:
          request = json.loads(line)
          method = request['method']
          response = {'jsonrpc': '2.0', 'id': request['id']}
          if method == 'initialize' and os.path.exists(os.path.join(project, 'fail')):
              response['error'] = {'code': -32000, 'message': 'fixture open failed'}
          else:
              values = {'initialize': {'protocolVersion': 1},
                        'project.inspect': {'root': project, 'containers': [], 'swiftPackages': [],
                                            'diagnostics': [], 'scanTruncated': False},
                        'config.get': {}, 'run.list': [], 'environment.list': []}
              response['result'] = values.get(method, {})
          print(json.dumps(response), flush=True)
      """#
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("data"), agentExecutable: executable)
    await store.restore()
    await store.open(source)
    XCTAssertTrue(store.connected)
    store.library.tasks = [.init(id: "current", project: source.path, title: "Current", runIDs: []),
      .init(id: "source", project: target.path, title: "Fork source", runIDs: ["finished"])]
    store.library.chatRuns = [.init(id: "finished", kind: "chat", project: target.path,
      status: "succeeded", createdAt: 1, updatedAt: 2, request: .null,
      result: .object(["response": .string("completed response")]))]
    store.library.notes["finished"] = "completed prompt"
    store.selectTask(store.library.tasks[0])
    store.draft = "keep displayed draft"
    store.workspace.fileText = "keep preview"
    store.navigationForward = [.init(project: source.path, run: "older")]
    store.toggleActivity()
    let back = store.navigationBack, forward = store.navigationForward
    let created = await store.forkTaskFromMenu("source")
    let fork = try XCTUnwrap(created)
    XCTAssertEqual(fork.project, target.path)
    XCTAssertEqual(store.library.chatContext(taskID: fork.id).map(\.content),
      ["completed prompt", "completed response"])
    if failing {
      XCTAssertEqual(store.selectedTask?.id, "current")
      XCTAssertEqual(store.project?.path, source.path)
      XCTAssertEqual(store.draft, "keep displayed draft")
      XCTAssertEqual(store.workspace.fileText, "keep preview")
      XCTAssertEqual(store.navigationBack, back)
      XCTAssertEqual(store.navigationForward, forward)
      XCTAssertFalse(store.connected)
      XCTAssertNotNil(store.activityError)
      let notice = try XCTUnwrap(store.notices.items.first { $0.taskID == fork.id })
      XCTAssertEqual(try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
        .tasks.first?.id, fork.id)
      try FileManager.default.removeItem(at: failureMarker)
      await store.openNoticeTask(notice)
    }
    XCTAssertTrue(store.connected, store.error ?? "")
    XCTAssertEqual(store.project?.path, target.path)
    XCTAssertEqual(store.selectedTask?.id, fork.id)
    XCTAssertEqual(store.library.drafts["current"], "keep displayed draft")
    XCTAssertEqual(store.navigationBack.last?.project, source.path)
    XCTAssertEqual(store.navigationBack.last?.run, "current")
    XCTAssertNil(store.taskMenuForkingID)
    XCTAssertEqual(store.library.tasks.count, 3)
    await store.shutdown()
  }
  func testCrossProjectForkOpensOnlyPersistedFork() async throws { try await checkOpen(failing: false) }
  func testCrossProjectOpenFailurePreservesWorkspaceAndCanReopenSavedFork() async throws {
    try await checkOpen(failing: true)
  }
}
