import XCTest
@testable import ShipiOS

@MainActor final class SubagentSubmissionTests: XCTestCase {
  private func fixture() throws -> (WorkspaceStore, ImageAttachment, FileAttachment) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("child-submission-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    let child = CodexSubagent(rootThreadID: "root", threadID: "child", status: .completed, loaded: true, observedAtMs: 0)
    store.library.tasks = [.init(id: "task", project: "", title: "Parent", runIDs: [], codexThreadID: "root", codexSubagents: [child])]
    let source = root.appendingPathComponent("原始文件.txt"); try Data("file text".utf8).write(to: source)
    return (store, try ImageAttachmentStorage.importData(AttachmentFixture.png(), name: "原始图片.png", root: root),
      try FileAttachmentStorage.importFile(source, root: root))
  }
  private func record(_ image: ImageAttachment, _ file: FileAttachment, task: String = "task", child: String = "child") -> SubagentSubmission {
    .init(taskID: task, rootThreadID: "root", childThreadID: child,
      message: .init(role: "user", content: "原始提示", images: [image], files: [file]), wireText: "expanded reference", expectedTurnID: nil)
  }
  private func history(_ image: ImageAttachment, root: URL, turn: String = "turn", text: String = "expanded reference") -> SubagentTranscript {
    .init(events: [
      .object(["type": .string("task_started"), "turn_id": .string(turn)]),
      .object(["type": .string("user_message"), "message": .string(text),
        "local_images": .array([.string(ImageAttachmentStorage.url(image, root: root).resolvingSymlinksInPath().path)])])])
  }
  func testPendingMetadataPersistsBeforeAcknowledgementAndLegacyLibraryDecodes() throws {
    let (store, image, file) = try fixture(), pending = record(image, file)
    try store.recordSubagentSubmission(pending)
    let restored = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    XCTAssertEqual(restored.subagentSubmissions, [pending]); XCTAssertEqual(restored.fileReferences[file.id], file)
    XCTAssertEqual(restored.imageReferences[image.id], image)
    XCTAssertTrue(try JSONDecoder().decode(WorkspaceLibrary.self, from: Data("{}".utf8)).subagentSubmissions.isEmpty)
    XCTAssertFalse(String(decoding: try JSONEncoder().encode(pending), as: UTF8.self).contains("expanded reference"),
      "Persist a digest, not another copy of expanded file contents")
  }
  func testActualHistoryBindingRestoresNamesFilesAndOriginalPromptWithoutInventingHistory() throws {
    let (store, image, file) = try fixture()
    var accepted = record(image, file); accepted.phase = .accepted; accepted.turnID = "turn"
    let original = history(image, root: store.dataRoot)
    let projected = original.attaching([accepted], root: store.dataRoot)
    XCTAssertEqual(projected.entries.first?.text, "原始提示")
    XCTAssertEqual(projected.entries.first?.images, [image]); XCTAssertEqual(projected.entries.first?.files, [file])
    XCTAssertEqual(projected.entries.first?.id, original.entries.first?.id)
    XCTAssertEqual(projected.activeTurnID, original.activeTurnID)
    XCTAssertTrue(SubagentTranscript().attaching([accepted], root: store.dataRoot).entries.isEmpty)
    for mismatch in [history(image, root: store.dataRoot, turn: "other"), history(image, root: store.dataRoot, text: "altered reference")] {
      XCTAssertEqual(mismatch.attaching([accepted], root: store.dataRoot), mismatch)
    }
    var foreign = original; foreign.entries[0].localImagePaths = [store.dataRoot.appendingPathComponent("outside.png").path]
    XCTAssertEqual(foreign.attaching([accepted], root: store.dataRoot), foreign)
  }
  func testRepeatedMessagesConsumeMetadataOnceAndSteeringRequiresExactNativeTurn() throws {
    let (store, image, file) = try fixture()
    var accepted = record(image, file); accepted.phase = .accepted; accepted.turnID = "turn"
    var transcript = history(image, root: store.dataRoot)
    var second = try XCTUnwrap(transcript.entries.first)
    second = .init(id: "second", kind: .user, title: nil, text: second.text, localImagePaths: second.localImagePaths, turnID: "turn")
    transcript.entries.append(second)
    let projected = transcript.attaching([accepted], root: store.dataRoot)
    XCTAssertTrue(projected.entries[0].hasAttachmentMetadata); XCTAssertFalse(projected.entries[1].hasAttachmentMetadata)
    let steered = SubagentSubmission(taskID: "task", rootThreadID: "root", childThreadID: "child",
      message: accepted.message, wireText: "expanded reference", expectedTurnID: "other")
    XCTAssertEqual(transcript.attaching([steered], root: store.dataRoot), transcript)
  }
  func testRootDraftRemovalAndTaskDeletionKeepSharedAssetsUntilLastOwnerIsDeleted() throws {
    let (store, image, file) = try fixture()
    store.library.draftImages["draft"] = [image]; store.library.draftFiles["draft"] = [file]
    try store.recordSubagentSubmission(record(image, file))
    store.removeDraftImage(image, draft: "draft"); store.removeDraftFile(file, draft: "draft")
    XCTAssertNoThrow(try ImageAttachmentStorage.data(image, root: store.dataRoot))
    XCTAssertNoThrow(try FileAttachmentStorage.text(file, root: store.dataRoot))
    var peer = store.library.tasks[0]; peer.id = "peer"; peer.archived = true
    store.library.tasks.append(peer); try store.recordSubagentSubmission(record(image, file, task: "peer"))
    var candidate = store.library; candidate.tasks[0].archived = true
    candidate.deleteArchivedTasks(["task"]); try store.commitLibrary(candidate)
    XCTAssertEqual(store.library.subagentSubmissions.map(\.taskID), ["peer"])
    XCTAssertNoThrow(try FileAttachmentStorage.text(file, root: store.dataRoot))
    candidate = store.library; candidate.deleteArchivedTasks(["peer"]); try store.commitLibrary(candidate)
    XCTAssertTrue(store.library.subagentSubmissions.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: FileAttachmentStorage.url(file, root: store.dataRoot).path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: ImageAttachmentStorage.url(image, root: store.dataRoot).path))
  }
  func testForeignOwnersUnloadedChildrenAndLateAcknowledgementsCannotCreateRecords() throws {
    let (store, image, file) = try fixture()
    XCTAssertThrowsError(try store.recordSubagentSubmission(record(image, file, task: "foreign")))
    XCTAssertThrowsError(try store.recordSubagentSubmission(record(image, file, child: "root")))
    let pending = record(image, file); try store.recordSubagentSubmission(pending)
    var candidate = store.library; candidate.tasks[0].archived = true; candidate.deleteArchivedTasks(["task"])
    try store.commitLibrary(candidate)
    var late = pending; late.phase = .accepted; late.turnID = "turn"
    XCTAssertThrowsError(try store.recordSubagentSubmission(late)); XCTAssertTrue(store.library.subagentSubmissions.isEmpty)
    store.library.tasks = [.init(id: "task", project: "", title: "Cold", runIDs: [], codexThreadID: "root", codexSubagents: [
      .init(rootThreadID: "root", threadID: "child", status: .notLoaded, loaded: false, observedAtMs: 0)])]
    XCTAssertThrowsError(try store.recordSubagentSubmission(record(image, file)))
  }
  func testSaveFailureBlocksSubmissionButAcknowledgementKeepsInMemoryAssetsAndReportsError() throws {
    let (store, image, file) = try fixture(), pending = record(image, file)
    let path = store.dataRoot.appendingPathComponent("workspace.json")
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    XCTAssertThrowsError(try store.recordSubagentSubmission(pending))
    XCTAssertTrue(store.library.subagentSubmissions.isEmpty)
    try FileManager.default.removeItem(at: path); try store.recordSubagentSubmission(pending)
    try FileManager.default.removeItem(at: path); try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    var accepted = pending; accepted.phase = .accepted; accepted.turnID = "turn"
    XCTAssertThrowsError(try store.recordSubagentSubmission(accepted))
    XCTAssertEqual(store.library.subagentSubmissions, [accepted]); XCTAssertNotNil(store.error)
    XCTAssertEqual(store.library.imageReferences[image.id], image)
  }
  func testUnconfirmedInputUsesOnlyMatchingNativeHistoryAndRetainsIntegrityMetadataAfterReload() throws {
    let (store, image, file) = try fixture(), pending = record(image, file)
    try store.recordSubagentSubmission(pending)
    var uncertain = pending; uncertain.phase = .unconfirmed
    try store.recordSubagentSubmission(uncertain)
    let restored = WorkspaceStore(dataRoot: store.dataRoot)
    restored.library = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json"))
    restored.libraryLoaded = true
    let scoped = restored.subagentSubmissions(taskID: "task", rootThreadID: "root", childThreadID: "child")
    XCTAssertEqual(scoped, [uncertain])
    XCTAssertTrue(restored.subagentSubmissions(taskID: "peer", rootThreadID: "root", childThreadID: "child").isEmpty)
    XCTAssertEqual(history(image, root: store.dataRoot).attaching(scoped, root: store.dataRoot).entries.first?.files, [file])
    try Data("tampered".utf8).write(to: ImageAttachmentStorage.url(image, root: store.dataRoot))
    XCTAssertThrowsError(try ImageAttachmentStorage.data(try XCTUnwrap(scoped.first?.message.images.first), root: store.dataRoot))
    try Data("tampered".utf8).write(to: FileAttachmentStorage.url(file, root: store.dataRoot))
    XCTAssertThrowsError(try FileAttachmentStorage.text(try XCTUnwrap(scoped.first?.message.files.first), root: store.dataRoot))
  }
}
