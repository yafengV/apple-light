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
  @MainActor func testColdChildDraftLoadsAndSendsWithoutInventingAParentTurn() async throws {
    try Data().write(to: gate)
    let original = try await makeStore(), (task, run, child) = try await parent(original)
    let detail = SubagentDetailState(); detail.bindDrafts(to: original, taskID: task); detail.select(child)
    detail.draft = "subagent-child-followup cold draft🙂"
    let source = root.appendingPathComponent("cold-reference.txt"); try Data("冷草稿附件".utf8).write(to: source)
    let imported = await detail.importAttachments([.image(try AttachmentFixture.png(), name: "cold.png"), .file(source)], root: original.dataRoot)
    XCTAssertTrue(imported)
    let images = detail.images, files = detail.files, runs = original.library.tasks.first { $0.id == task }?.runIDs
    await original.shutdown()
    let before = try requests().count
    let restored = try await makeStore()
    let selected = await restored.selectTaskAwaitingScope(try XCTUnwrap(restored.library.tasks.first { $0.id == task }))
    XCTAssertTrue(selected)
    try await waitFor { !restored.busy && !restored.restoringLibrary }
    let cold = try XCTUnwrap(restored.subagents(taskID: task).first { $0.id == child.id })
    XCTAssertFalse(cold.loaded)
    async let first: Void = restored.prepareSubagent(taskID: task, agent: cold)
    async let second: Void = restored.prepareSubagent(taskID: task, agent: cold)
    _ = try await (first, second)
    XCTAssertEqual(try requests().count, before, "Connecting and loading must not generate a parent model request")
    XCTAssertEqual(restored.library.tasks.first { $0.id == task }?.runIDs, runs)
    XCTAssertEqual(restored.library.tasks.first { $0.id == task }?.codexThreadID, child.rootThreadID)
    let loaded = try XCTUnwrap(restored.subagents(taskID: task).first { $0.id == child.id })
    XCTAssertTrue(loaded.acceptsInput); XCTAssertFalse(loaded.working)
    let fresh = SubagentDetailState(); fresh.bindDrafts(to: restored, taskID: task); fresh.select(loaded)
    XCTAssertEqual(fresh.images, images); XCTAssertEqual(fresh.files, files); XCTAssertEqual(fresh.draft, "subagent-child-followup cold draft🙂")
    let sent = await fresh.sendMessage(working: loaded.working) { agent, message, turn in
      try await restored.codexTransport.submitSubagent(taskID: task, rootThreadID: agent.rootThreadID,
        childThreadID: agent.threadID, text: message.content, expectedTurnID: turn, images: message.images, files: message.files)
    }
    XCTAssertTrue(sent, fresh.error ?? ""); XCTAssertFalse(fresh.hasInput)
    let acceptedTurn = try XCTUnwrap(restored.subagentSubmissions(taskID: task,
      rootThreadID: child.rootThreadID, childThreadID: child.threadID).last?.turnID)
    try await waitFor {
      restored.subagentLiveStates[child.id]?.events.contains {
        $0["type"].text == "task_complete" && $0["turn_id"].text == acceptedTurn
      } == true
    }
    try await waitFor { restored.subagents(taskID: task).first { $0.id == child.id }?.status == .completed }
    let events = try await restored.codexTransport.readSubagentHistory(taskID: task, rootThreadID: child.rootThreadID, childThreadID: child.threadID)
    let projected = SubagentTranscript(events: events).attaching(restored.subagentSubmissions(taskID: task,
      rootThreadID: child.rootThreadID, childThreadID: child.threadID), root: restored.dataRoot)
    XCTAssertEqual(projected.entries.last { $0.hasAttachmentMetadata }?.images, images)
    XCTAssertEqual(projected.entries.last { $0.hasAttachmentMetadata }?.files, files)
    XCTAssertEqual(restored.library.tasks.first { $0.id == task }?.runIDs, runs)
    XCTAssertEqual(restored.library.chatRuns.first { $0.id == run }?.result?["response"].text, "Parent finished while child continues")
    let after = try requests().count
    for invalid in [child.rootThreadID, UUID().uuidString] {
      do { _ = try await restored.codexTransport.loadSubagent(taskID: task, rootThreadID: child.rootThreadID, childThreadID: invalid); XCTFail("Foreign child loaded") }
      catch {}
    }
    XCTAssertEqual(try requests().count, after)
  }
  @MainActor func testRecordedClosedChildOpensHistoryWithoutReloadingOrSubmittingIt() async throws {
    try Data().write(to: gate)
    let original = try await makeStore(), (task, _, child) = try await parent(original)
    let taskIndex = try XCTUnwrap(original.library.tasks.firstIndex { $0.id == task })
    let childIndex = try XCTUnwrap(original.library.tasks[taskIndex].codexSubagents?.firstIndex { $0.id == child.id })
    // Seed the persisted UI observation; native close_agent behavior is a separate contract.
    original.library.tasks[taskIndex].codexSubagents![childIndex].status = .shutdown
    original.saveLibrary(); await original.shutdown()
    let before = try requests().count, restored = try await makeStore()
    let cold = try XCTUnwrap(restored.subagents(taskID: task).first { $0.id == child.id })
    XCTAssertEqual(cold.status, .shutdown); XCTAssertFalse(cold.loaded)
    try await restored.prepareSubagent(taskID: task, agent: cold)
    let history = try await restored.codexTransport.readSubagentHistory(taskID: task,
      rootThreadID: child.rootThreadID, childThreadID: child.threadID)
    XCTAssertTrue(SubagentTranscript(events: history).entries.contains { $0.text == "Native child finished" })
    let after = try XCTUnwrap(restored.subagents(taskID: task).first { $0.id == child.id })
    XCTAssertEqual(after.status, .shutdown); XCTAssertFalse(after.loaded); XCTAssertFalse(after.acceptsInput)
    XCTAssertEqual(try requests().count, before)
  }
  @MainActor func testMixedChildImageAndFileReachActualCoreAndCannotTargetParentOrPeer() async throws {
    try Data().write(to: gate)
    let store = try await makeStore(), (task, run, child) = try await parent(store)
    store.newTask()
    let (peerTask, peerRun, peerChild) = try await parent(store)
    XCTAssertNotEqual(task, peerTask)
    let detail = SubagentDetailState(); detail.bindDrafts(to: store, taskID: task)
    detail.select(child); detail.draft = "subagent-child-followup mixed"
    let textFile = root.appendingPathComponent("child.txt"); try Data("独立子文件🙂".utf8).write(to: textFile)
    let imported = await detail.importAttachments([.image(try AttachmentFixture.png(), name: "child.png"), .file(textFile)], root: store.dataRoot)
    XCTAssertTrue(imported)
    let draftScope = SubagentDraftScope(taskID: task, rootThreadID: child.rootThreadID, childThreadID: child.threadID)
    let images = detail.images, files = detail.files
    detail.select(nil); detail.select(child)
    let remounted = SubagentDetailState(); remounted.bindDrafts(to: store, taskID: task); remounted.select(child)
    XCTAssertEqual(remounted.draft, "subagent-child-followup mixed")
    XCTAssertEqual(remounted.images, images); XCTAssertEqual(remounted.files, files)
    XCTAssertEqual(try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
      .subagentDrafts.first { $0.scope == draftScope }?.message.files, files)
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
    XCTAssertTrue(sent, detail.error ?? ""); XCTAssertFalse(detail.hasInput); XCTAssertFalse(remounted.hasInput)
    XCTAssertNil(store.subagentDraft(draftScope))
    for image in images { XCTAssertEqual(store.library.imageReferences[image.id], image) }
    for file in files { XCTAssertEqual(store.library.fileReferences[file.id], file) }
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
    let projected = SubagentTranscript(events: after).attaching(store.subagentSubmissions(taskID: task,
      rootThreadID: child.rootThreadID, childThreadID: child.threadID), root: store.dataRoot)
    XCTAssertEqual(projected.entries.last { $0.hasAttachmentMetadata }?.files, [file])
    XCTAssertEqual(projected.entries.last { $0.hasAttachmentMetadata }?.text, "")
    XCTAssertEqual(projected.entries.first { $0.hasAttachmentMetadata }?.images, [image])
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
      let projected = SubagentTranscript(events: history).attaching(store.subagentSubmissions(taskID: task,
        rootThreadID: child.rootThreadID, childThreadID: child.threadID), root: store.dataRoot)
      XCTAssertEqual(projected.entries.last { $0.hasAttachmentMetadata }?.files,
        store.library.subagentSubmissions.last?.message.files)
      XCTAssertEqual(projected.entries.last { $0.hasAttachmentMetadata }?.files.first?.isPDF, source == pdf)
      XCTAssertEqual(projected.entries.last { $0.hasAttachmentMetadata }?.files.first?.representsDirectory, source == folder)
    }
    XCTAssertEqual(store.library.chatRuns.first { $0.id == run }?.result?["response"].text, "Parent finished while child continues")
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.dataRoot.appendingPathComponent("CodexStaging").path).isEmpty)
  }
  @MainActor func testNativeAttachmentHistoryAndSharedReferencesSurviveColdParentResume() async throws {
    try Data().write(to: gate)
    let store = try await makeStore(), (task, _, child) = try await parent(store)
    let source = root.appendingPathComponent("original child.txt")
    try Data("durable child file body".utf8).write(to: source)
    let image = try ImageAttachmentStorage.importData(AttachmentFixture.png(), name: "original child.png", root: store.dataRoot)
    let file = try FileAttachmentStorage.importFile(source, root: store.dataRoot)
    store.library.draftImages["parent-draft"] = [image]; store.library.draftFiles["parent-draft"] = [file]
    let save = try XCTUnwrap(store.codexTransport.onSubagentSubmission)
    var sawSavedPending = false
    store.codexTransport.onSubagentSubmission = { record in
      try save(record)
      if record.phase == .pending {
        let disk = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
        XCTAssertEqual(disk.subagentSubmissions.last, record)
        store.removeDraftImage(image, draft: "parent-draft"); store.removeDraftFile(file, draft: "parent-draft")
        XCTAssertNoThrow(try ImageAttachmentStorage.data(image, root: store.dataRoot))
        XCTAssertNoThrow(try FileAttachmentStorage.text(file, root: store.dataRoot))
        sawSavedPending = true
      }
    }
    let prompt = "subagent-child-followup original prompt"
    let turn = try await store.codexTransport.submitSubagent(taskID: task, rootThreadID: child.rootThreadID,
      childThreadID: child.threadID, text: prompt, expectedTurnID: nil, images: [image], files: [file])
    XCTAssertTrue(sawSavedPending)
    try await waitFor { try self.requests().contains { $0["text"].text?.contains("durable child file body") == true } }
    try await waitFor { store.subagents(taskID: task).first { $0.id == child.id }?.status == .completed }
    let records = store.subagentSubmissions(taskID: task, rootThreadID: child.rootThreadID, childThreadID: child.threadID)
    XCTAssertEqual(records.last?.phase, .accepted); XCTAssertEqual(records.last?.turnID, turn)
    let events = try await store.codexTransport.readSubagentHistory(taskID: task, rootThreadID: child.rootThreadID, childThreadID: child.threadID)
    let projected = SubagentTranscript(events: events).attaching(records, root: store.dataRoot)
    let input = try XCTUnwrap(projected.entries.last { $0.kind == .user && $0.hasAttachmentMetadata })
    XCTAssertEqual(input.text, prompt); XCTAssertEqual(input.images, [image]); XCTAssertEqual(input.files, [file])
    await store.shutdown()
    let reopened = try await makeStore()
    let restoredTask = try XCTUnwrap(reopened.library.tasks.first { $0.id == task })
    XCTAssertEqual(restoredTask.codexThreadID, child.rootThreadID)
    let selected = await reopened.selectTaskAwaitingScope(restoredTask); XCTAssertTrue(selected)
    let nextStarted = await reopened.startChat("subagent-parent-complete")
    let nextRun = try XCTUnwrap(nextStarted)
    try await waitFor { reopened.library.chatRuns.first { $0.id == nextRun }?.isActive == false }
    XCTAssertEqual(reopened.library.tasks.first { $0.id == task }?.codexThreadID, child.rootThreadID)
    let coldEvents = try await reopened.codexTransport.readSubagentHistory(taskID: task,
      rootThreadID: child.rootThreadID, childThreadID: child.threadID)
    let cold = SubagentTranscript(events: coldEvents).attaching(reopened.subagentSubmissions(taskID: task,
      rootThreadID: child.rootThreadID, childThreadID: child.threadID), root: reopened.dataRoot)
    let recovered = try XCTUnwrap(cold.entries.last { $0.hasAttachmentMetadata })
    XCTAssertEqual(recovered.text, prompt); XCTAssertEqual(recovered.images, [image]); XCTAssertEqual(recovered.files, [file])
    XCTAssertEqual(try FileAttachmentStorage.text(file, root: reopened.dataRoot), "durable child file body")
    XCTAssertNoThrow(try ImageAttachmentStorage.data(image, root: reopened.dataRoot))
  }
  @MainActor func testAcceptedChildInputIsNotReportedAsFailedWhenAcknowledgementMetadataSaveFails() async throws {
    try Data().write(to: gate)
    let store = try await makeStore(), (task, _, child) = try await parent(store)
    let image = try ImageAttachmentStorage.importData(AttachmentFixture.png(), name: "ack.png", root: store.dataRoot)
    let save = try XCTUnwrap(store.codexTransport.onSubagentSubmission)
    store.codexTransport.onSubagentSubmission = { record in
      if record.phase == .accepted { throw AgentFailure(message: "injected acknowledgement save failure") }
      try save(record)
    }
    let detail = SubagentDetailState(); detail.select(child); detail.images = [image]
    let sent = await detail.sendMessage(working: false) { agent, message, turn in
      try await store.codexTransport.submitSubagent(taskID: task, rootThreadID: agent.rootThreadID,
        childThreadID: agent.threadID, text: message.content, expectedTurnID: turn, images: message.images)
    }
    XCTAssertTrue(sent, detail.error ?? ""); XCTAssertTrue(detail.images.isEmpty)
    let pending = store.subagentSubmissions(taskID: task, rootThreadID: child.rootThreadID, childThreadID: child.threadID)
    XCTAssertEqual(pending.last?.phase, .pending); XCTAssertEqual(store.library.imageReferences[image.id], image)
    try await waitFor { try self.requests().contains { !$0["imageUrls"].items.isEmpty } }
    let history = try await store.codexTransport.readSubagentHistory(taskID: task,
      rootThreadID: child.rootThreadID, childThreadID: child.threadID)
    XCTAssertEqual(SubagentTranscript(events: history).attaching(pending, root: store.dataRoot).entries.last { $0.hasAttachmentMetadata }?.images, [image])
  }

}
