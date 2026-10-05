import XCTest
@testable import ShipiOS

final class SubagentAttachmentIntegrationTests: XCTestCase {
  private let root = FileManager.default.temporaryDirectory.appendingPathComponent("actual-child-attachments-\(UUID())")
  private var server: Process!
  private var endpoint = ""
  private var gate: URL { root.appendingPathComponent("gate") }
  private var requestLog: URL { root.appendingPathComponent("requests.jsonl") }
  override func setUpWithError() throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = ["-u", URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/subagent_server.py").path]
    server.environment = ProcessInfo.processInfo.environment.merging([
      "SHIPIOS_SUBAGENT_COMPLETE_GATE": gate.path, "SHIPIOS_SUBAGENT_REQUEST_LOG": requestLog.path]) { _, new in new }
    let output = Pipe(); server.standardOutput = output; server.standardError = FileHandle.nullDevice
    try server.run()
    let port = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard Int(port) != nil else { throw AgentFailure(message: "Child attachment fixture did not start") }
    endpoint = "http://127.0.0.1:\(port)/v1"
  }
  override func tearDown() {
    if server?.isRunning == true { server.terminate(); server.waitUntilExit() }
    try? FileManager.default.removeItem(at: root)
  }
  @MainActor private func makeStore() async throws -> WorkspaceStore {
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: try AgentTestExecutable.url())
    await store.restore(); await store.openProjectless()
    var config = ModelConfiguration(); config.apiProtocol = .codexResponses; config.baseURL = endpoint; config.model = "gpt-5.4"
    try store.saveModelConfiguration(config); store.notificationPreferences = .init(timing: .never)
    addTeardownBlock { await store.shutdown() }
    return store
  }
  @MainActor private func waitFor(_ condition: () throws -> Bool) async throws {
    let end = ContinuousClock.now.advanced(by: .seconds(20))
    while try !condition() { guard ContinuousClock.now < end else { throw AgentFailure(message: "Child attachment flow timed out") }; try await Task.sleep(for: .milliseconds(20)) }
  }
  @MainActor private func parent(_ store: WorkspaceStore, stream: Bool = false) async throws -> (String, String, CodexSubagent) {
    let started = await store.startChat(stream ? "subagent-parent-stream" : "subagent-parent-complete")
    let run = try XCTUnwrap(started), task = try XCTUnwrap(store.library.task(containing: run)?.id)
    try await waitFor { store.library.chatRuns.first { $0.id == run }?.isActive == false && !store.subagents(taskID: task).isEmpty }
    let child = try XCTUnwrap(store.subagents(taskID: task).first)
    if !stream { try await waitFor { store.subagents(taskID: task).first { $0.id == child.id }?.status == .completed } }
    return (task, run, child)
  }
  private func requests() throws -> [JSONValue] {
    try String(contentsOf: requestLog, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
  }
  @MainActor func testMixedChildImageAndFileReachActualCoreAndCannotTargetParentOrPeer() async throws {
    try Data().write(to: gate)
    let store = try await makeStore(), (task, run, child) = try await parent(store)
    store.newTask()
    let (peerTask, peerRun, peerChild) = try await parent(store)
    XCTAssertNotEqual(task, peerTask)
    let detail = SubagentDetailState(); detail.select(child); detail.draft = "subagent-child-followup mixed"
    let textFile = root.appendingPathComponent("child.txt"); try Data("独立子文件🙂".utf8).write(to: textFile)
    let imported = await detail.importAttachments([.image(try AttachmentFixture.png(), name: "child.png"), .file(textFile)], root: store.dataRoot)
    XCTAssertTrue(imported)
    for wrong in [child.rootThreadID, peerChild.threadID] {
      do {
        _ = try await store.codexTransport.submitSubagent(taskID: task, rootThreadID: child.rootThreadID,
          childThreadID: wrong, text: detail.draft, expectedTurnID: nil, images: detail.images, files: detail.files)
        XCTFail("Foreign child attachment input was accepted")
      } catch {}
    }
    XCTAssertFalse(try requests().contains { !$0["imageUrls"].items.isEmpty })
    let png = try ImageAttachmentStorage.data(try XCTUnwrap(detail.images.first), root: store.dataRoot)
    let sent = await detail.sendMessage(working: false) { agent, message, turn in
      try await store.codexTransport.submitSubagent(taskID: task, rootThreadID: agent.rootThreadID, childThreadID: agent.threadID,
        text: message.content, expectedTurnID: turn, images: message.images, files: message.files)
    }
    XCTAssertTrue(sent, detail.error ?? ""); XCTAssertFalse(detail.hasInput)
    try await waitFor { try self.requests().contains { !$0["imageUrls"].items.isEmpty } }
    let request = try XCTUnwrap(try requests().first { !$0["imageUrls"].items.isEmpty })
    XCTAssertTrue(request["text"].text?.contains("独立子文件🙂") == true)
    XCTAssertEqual(request["imageUrls"].items.first?.text, "data:image/png;base64," + png.base64EncodedString())
    try await waitFor { store.subagents(taskID: task).first { $0.id == child.id }?.status == .completed }
    for id in [run, peerRun] { XCTAssertEqual(store.library.chatRuns.first { $0.id == id }?.result?["response"].text, "Parent finished while child continues") }
    XCTAssertEqual(store.subagents(taskID: peerTask).first?.preview, "Native child finished")
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.dataRoot.appendingPathComponent("CodexStaging").path).isEmpty)
  }
  @MainActor func testImageOnlyAndFileOnlyMessagesHaveActualChildHistoryAndReleaseStaging() async throws {
    try Data().write(to: gate)
    let store = try await makeStore(), (task, run, child) = try await parent(store)
    let image = try ImageAttachmentStorage.importData(try AttachmentFixture.png(), name: "only.png", root: store.dataRoot)
    _ = try await store.codexTransport.submitSubagent(taskID: task, rootThreadID: child.rootThreadID,
      childThreadID: child.threadID, text: "", expectedTurnID: nil, images: [image])
    try await waitFor { try self.requests().contains { !$0["imageUrls"].items.isEmpty } }
    try await waitFor { store.subagents(taskID: task).first { $0.id == child.id }?.status == .completed }
    let history = try await store.codexTransport.readSubagentHistory(taskID: task, rootThreadID: child.rootThreadID, childThreadID: child.threadID)
    let transcript = SubagentTranscript(events: history)
    let picture = try XCTUnwrap(transcript.entries.first { !$0.localImagePaths.isEmpty })
    XCTAssertEqual(try ImageAttachmentStorage.storedImage(path: try XCTUnwrap(picture.localImagePaths.first), root: store.dataRoot).id, image.id)
    let source = root.appendingPathComponent("only.txt"); try Data("file-only child reference".utf8).write(to: source)
    let file = try FileAttachmentStorage.importFile(source, root: store.dataRoot)
    _ = try await store.codexTransport.submitSubagent(taskID: task, rootThreadID: child.rootThreadID,
      childThreadID: child.threadID, text: "", expectedTurnID: nil, files: [file])
    try await waitFor { try self.requests().contains { $0["text"].text?.contains("file-only child reference") == true } }
    try await waitFor { store.subagents(taskID: task).first { $0.id == child.id }?.status == .completed }
    let after = try await store.codexTransport.readSubagentHistory(taskID: task, rootThreadID: child.rootThreadID, childThreadID: child.threadID)
    XCTAssertTrue(SubagentTranscript(events: after).entries.contains { $0.kind == .user && $0.text.contains("file-only child reference") })
    XCTAssertEqual(store.library.chatRuns.first { $0.id == run }?.result?["response"].text, "Parent finished while child continues")
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.dataRoot.appendingPathComponent("CodexStaging").path).isEmpty)
  }
  @MainActor func testActualChildAttachmentSteeringUsesItsTurnAndRejectsChangedSnapshots() async throws {
    let store = try await makeStore(), (task, run, child) = try await parent(store, stream: true)
    try await waitFor { SubagentTranscript(events: store.subagentLiveStates[child.id]?.events ?? []).activeTurnID != nil }
    let turn = try XCTUnwrap(SubagentTranscript(events: store.subagentLiveStates[child.id]?.events ?? []).activeTurnID)
    let png = try AttachmentFixture.png(), image = try ImageAttachmentStorage.importData(png, name: "steer.png", root: store.dataRoot)
    let path = ImageAttachmentStorage.url(image, root: store.dataRoot)
    try Data("changed".utf8).write(to: path)
    do {
      _ = try await store.codexTransport.submitSubagent(taskID: task, rootThreadID: child.rootThreadID,
        childThreadID: child.threadID, text: "subagent-child-followup", expectedTurnID: turn, images: [image])
      XCTFail("Changed image snapshot was sent")
    } catch {}
    try png.write(to: path)
    do {
      _ = try await store.codexTransport.submitSubagent(taskID: task, rootThreadID: child.rootThreadID,
        childThreadID: child.threadID, text: "subagent-child-followup", expectedTurnID: "foreign-turn", images: [image])
      XCTFail("Wrong child turn was steered")
    } catch {}
    _ = try await store.codexTransport.submitSubagent(taskID: task, rootThreadID: child.rootThreadID,
      childThreadID: child.threadID, text: "subagent-child-followup", expectedTurnID: turn, images: [image])
    try Data().write(to: gate)
    try await waitFor { try self.requests().contains { !$0["imageUrls"].items.isEmpty } }
    XCTAssertEqual(store.library.chatRuns.first { $0.id == run }?.result?["response"].text, "Parent finished while child continues")
  }
  @MainActor func testPDFAndFolderContextReachTheActualChildWithoutChangingParent() async throws {
    try Data().write(to: gate)
    let store = try await makeStore(), (task, run, child) = try await parent(store)
    let pdf = root.appendingPathComponent("child.pdf")
    try AttachmentFixture.pdf("Child PDF text").write(to: pdf)
    let folder = root.appendingPathComponent("child-folder")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("Child folder text".utf8).write(to: folder.appendingPathComponent("note.txt"))
    for (source, content) in [(pdf, "Child PDF text"), (folder, "Child folder text")] {
      let detail = SubagentDetailState(); detail.select(child)
      let imported = await detail.importAttachments([.file(source)], root: store.dataRoot)
      XCTAssertTrue(imported, detail.attachmentError ?? "")
      let sent = await detail.sendMessage(working: false) { agent, message, turn in
        try await store.codexTransport.submitSubagent(taskID: task, rootThreadID: agent.rootThreadID,
          childThreadID: agent.threadID, text: message.content, expectedTurnID: turn, files: message.files)
      }
      XCTAssertTrue(sent, detail.error ?? "")
      try await waitFor { try self.requests().contains { $0["text"].text?.contains(content) == true } }
      try await waitFor { store.subagents(taskID: task).first { $0.id == child.id }?.status == .completed }
      let history = try await store.codexTransport.readSubagentHistory(taskID: task, rootThreadID: child.rootThreadID, childThreadID: child.threadID)
      XCTAssertTrue(SubagentTranscript(events: history).entries.contains { $0.kind == .user && $0.text.contains(content) })
    }
    XCTAssertEqual(store.library.chatRuns.first { $0.id == run }?.result?["response"].text, "Parent finished while child continues")
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.dataRoot.appendingPathComponent("CodexStaging").path).isEmpty)
  }
}
