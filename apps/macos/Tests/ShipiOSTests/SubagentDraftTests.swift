import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import ShipiOS

@MainActor final class SubagentDraftTests: XCTestCase {
  private func fixture() throws -> WorkspaceStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("child-drafts-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    store.library.tasks = [.init(id: "task", project: "", title: "Parent", runIDs: [], codexThreadID: "root",
      codexSubagents: [agent(), agent("other")])]
    return store
  }
  private func agent(_ child: String = "child", loaded: Bool = true) -> CodexSubagent {
    .init(rootThreadID: "root", threadID: child, status: loaded ? .completed : .notLoaded, loaded: loaded, observedAtMs: 0)
  }
  private func scope(_ child: String = "child", task: String = "task") -> SubagentDraftScope {
    .init(taskID: task, rootThreadID: "root", childThreadID: child)
  }
  private func panel(_ store: WorkspaceStore, child: String = "child", task: String = "task") -> SubagentDetailState {
    let panel = SubagentDetailState(); panel.bindDrafts(to: store, taskID: task); panel.select(agent(child)); return panel
  }
  private func assets(_ store: WorkspaceStore) throws -> (ImageAttachment, FileAttachment) {
    let file = store.dataRoot.appendingPathComponent("原始草稿.txt")
    try Data("子任务参考内容".utf8).write(to: file)
    return (try ImageAttachmentStorage.importData(AttachmentFixture.png(), name: "草稿图片.png", root: store.dataRoot),
      try FileAttachmentStorage.importFile(file, root: store.dataRoot))
  }
  private func waitFor(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition() {
      guard ContinuousClock.now < deadline else { throw AgentFailure(message: "Draft operation did not start") }
      await Task.yield()
    }
  }
  func testSharedConversationDraftSurvivesBackRemountAndColdMetadataRestore() throws {
    let store = try fixture(), first = panel(store), second = panel(store)
    let (image, file) = try assets(store)
    first.draft = "保留未发送的草稿🙂"; first.images = [image]; first.files = [file]
    XCTAssertEqual(second.draft, first.draft); XCTAssertEqual(second.images, [image]); XCTAssertEqual(second.files, [file])
    first.select(agent("other")); first.draft = "另一子任务"
    XCTAssertEqual(second.selected?.threadID, "child"); XCTAssertEqual(second.draft, "保留未发送的草稿🙂")
    first.select(nil); first.select(agent())
    XCTAssertEqual(first.draft, second.draft); XCTAssertEqual(first.images, [image])
    let remounted = panel(store); XCTAssertEqual(remounted.files, [file])
    let cold = WorkspaceStore(dataRoot: store.dataRoot)
    cold.library = try WorkspaceLibrary.load(from: store.dataRoot.appendingPathComponent("workspace.json")); cold.libraryLoaded = true
    let restored = panel(cold); restored.select(agent(loaded: false))
    XCTAssertEqual(restored.draft, "保留未发送的草稿🙂"); XCTAssertEqual(restored.images, [image]); XCTAssertEqual(restored.files, [file])
    XCTAssertEqual(cold.library.subagentDrafts.count, 2)
    XCTAssertTrue(try JSONDecoder().decode(WorkspaceLibrary.self, from: Data("{}".utf8)).subagentDrafts.isEmpty)
  }
  func testParentAndChildDraftReferencesRetainAssetsUntilTheLastClear() throws {
    let store = try fixture(), first = panel(store), second = panel(store, child: "other")
    let (image, file) = try assets(store)
    store.library.draftImages["parent"] = [image]; store.library.draftFiles["parent"] = [file]
    first.images = [image]; first.files = [file]; second.images = [image]; second.files = [file]
    store.removeDraftImage(image, draft: "parent"); store.removeDraftFile(file, draft: "parent")
    first.clearDraft()
    XCTAssertNoThrow(try ImageAttachmentStorage.data(image, root: store.dataRoot))
    XCTAssertNoThrow(try FileAttachmentStorage.text(file, root: store.dataRoot))
    second.clearDraft()
    XCTAssertTrue(store.library.subagentDrafts.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: ImageAttachmentStorage.url(image, root: store.dataRoot).path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: FileAttachmentStorage.url(file, root: store.dataRoot).path))
  }
  func testStaleLibrarySaveCannotOverwriteNewInputAndDeletingTaskCannotResurrectIt() throws {
    let store = try fixture(), first = panel(store), peer = panel(store, task: "peer")
    var peerTask = store.library.tasks[0]; peerTask.id = "peer"; store.library.tasks.append(peerTask)
    let (image, file) = try assets(store)
    first.draft = "old"; var stale = store.library
    first.draft = "new"; first.images = [image]; first.files = [file]
    stale.tasks[0].title = "Renamed"; try store.commitLibrary(stale)
    XCTAssertEqual(first.draft, "new"); XCTAssertEqual(first.images, [image]); XCTAssertEqual(store.library.tasks[0].title, "Renamed")
    peer.images = [image]; peer.files = [file]; peer.draft = "peer input"
    var candidate = store.library; candidate.tasks[0].archived = true; candidate.deleteArchivedTasks(["task"])
    try store.commitLibrary(candidate)
    XCTAssertEqual(store.library.subagentDrafts.map(\.scope.taskID), ["peer"])
    XCTAssertThrowsError(try store.updateSubagentDraft(scope(), message: .init(role: "user", content: "late")))
    XCTAssertNoThrow(try FileAttachmentStorage.text(file, root: store.dataRoot))
    candidate = store.library; candidate.tasks[0].archived = true; candidate.deleteArchivedTasks(["peer"])
    try store.commitLibrary(candidate)
    XCTAssertTrue(store.library.subagentDrafts.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: ImageAttachmentStorage.url(image, root: store.dataRoot).path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: FileAttachmentStorage.url(file, root: store.dataRoot).path))
  }
  func testWriteFailureKeepsVisibleInputBlocksRPCAndRetryReclaimsRetiredAssets() async throws {
    let store = try fixture(), first = panel(store), second = panel(store)
    let (image, file) = try assets(store)
    first.draft = "original"; first.images = [image]; first.files = [file]
    let path = store.dataRoot.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: path); try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    first.images = []; first.files = []; first.draft = "visible despite disk failure"
    XCTAssertEqual(second.draft, first.draft); XCTAssertNotNil(second.draftSaveError)
    XCTAssertNoThrow(try ImageAttachmentStorage.data(image, root: store.dataRoot))
    XCTAssertNoThrow(try FileAttachmentStorage.text(file, root: store.dataRoot))
    var submitted = false
    let sent = await first.sendMessage(working: false) { _, _, _ in submitted = true; return "turn" }
    XCTAssertFalse(sent); XCTAssertFalse(submitted); XCTAssertFalse(first.sending); XCTAssertNil(first.error)
    XCTAssertFalse(second.retryDraftSave()); XCTAssertNotNil(first.draftSaveError)
    try FileManager.default.removeItem(at: path)
    XCTAssertTrue(second.retryDraftSave()); XCTAssertNil(first.draftSaveError); XCTAssertNil(second.error)
    XCTAssertEqual(try WorkspaceLibrary.load(from: path).subagentDrafts.first?.message.content, first.draft)
    XCTAssertFalse(FileManager.default.fileExists(atPath: ImageAttachmentStorage.url(image, root: store.dataRoot).path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: FileAttachmentStorage.url(file, root: store.dataRoot).path))
  }
  func testSharedClearInvalidatesAnotherPanelsPendingImportWithoutResurrectingDraft() async throws {
    let store = try fixture(), first = panel(store), second = panel(store)
    first.draft = "clear me"
    let provider = NSItemProvider(); var reply: ((Data?, Error?) -> Void)?
    provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
      Task { @MainActor in reply = completion }; return nil
    }
    let importing = Task { await first.importProviders([provider], root: store.dataRoot) }
    try await waitFor { reply != nil }
    second.clearDraft(); reply?(try AttachmentFixture.png(), nil)
    let accepted = await importing.value
    XCTAssertFalse(accepted); XCTAssertFalse(first.importing); XCTAssertFalse(first.hasInput); XCTAssertFalse(second.hasInput)
    XCTAssertTrue(store.library.subagentDrafts.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.dataRoot.appendingPathComponent("Attachments").path))
  }
  func testConcurrentImportsRecheckSharedLimitAndDiscardOnlyTheRejectedCopy() async throws {
    let store = try fixture(), first = panel(store), second = panel(store), png = try AttachmentFixture.png()
    let initial = await first.importAttachments((0..<7).map { .image(png, name: "\($0).png") }, root: store.dataRoot)
    XCTAssertTrue(initial)
    let provider = NSItemProvider(); var reply: ((Data?, Error?) -> Void)?
    provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
      Task { @MainActor in reply = completion }; return nil
    }
    let delayed = Task { await first.importProviders([provider], root: store.dataRoot) }
    try await waitFor { reply != nil }
    let eighth = await second.importAttachments([.image(png, name: "eighth.png")], root: store.dataRoot)
    XCTAssertTrue(eighth); reply?(png, nil)
    let ninth = await delayed.value
    XCTAssertFalse(ninth); XCTAssertNotNil(first.attachmentError); XCTAssertEqual(first.images.count, 8); XCTAssertEqual(second.images, first.images)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.dataRoot.appendingPathComponent("Attachments").path).count, 8)
    for image in first.images { XCTAssertNoThrow(try ImageAttachmentStorage.data(image, root: store.dataRoot)) }
  }
  func testAcknowledgementPreservesTextDeletedAndRetypedInAnotherPanel() async throws {
    let store = try fixture(), first = panel(store), second = panel(store)
    first.draft = "same text"
    var release: CheckedContinuation<String, Never>?
    let sending = Task { await first.sendMessage(working: false) { _, message, _ in
      XCTAssertEqual(message.content, "same text")
      return await withCheckedContinuation { release = $0 }
    } }
    try await waitFor { release != nil }
    second.draft = ""; second.draft = "same text"; release?.resume(returning: "turn")
    let accepted = await sending.value
    XCTAssertTrue(accepted); XCTAssertEqual(first.draft, "same text"); XCTAssertEqual(second.draft, "same text")
    XCTAssertFalse(first.sending)
  }
  func testConfirmedSendAfterBackClearsOriginalScopeAndKeepsNewChildDraft() async throws {
    let store = try fixture(), first = panel(store), observer = panel(store)
    first.draft = "submitted before Back"
    var release: CheckedContinuation<String, Never>?
    let sending = Task { await first.sendMessage(working: false) { _, _, _ in
      await withCheckedContinuation { release = $0 }
    } }
    try await waitFor { release != nil }
    first.select(nil); first.select(agent("other")); first.draft = "other child's draft"
    release?.resume(returning: "turn")
    let currentPanelSent = await sending.value
    XCTAssertFalse(currentPanelSent, "Do not refresh another child's panel for this acknowledgement")
    XCTAssertFalse(observer.hasInput); XCTAssertNil(store.subagentDraft(scope()))
    XCTAssertEqual(first.draft, "other child's draft"); XCTAssertNil(first.error); XCTAssertFalse(first.sending)
    first.select(agent()); XCTAssertFalse(first.hasInput)
  }
  func testAcknowledgementClearsOnlySubmittedAssetsAndKeepsNewSharedInput() async throws {
    let store = try fixture(), first = panel(store), second = panel(store)
    let (image, file) = try assets(store)
    first.draft = "submitted"; first.images = [image]; first.files = [file]
    let next = try ImageAttachmentStorage.importData(AttachmentFixture.png(), name: "next.png", root: store.dataRoot)
    let sent = await first.sendMessage(working: false) { child, message, _ in
      let pending = SubagentSubmission(taskID: "task", rootThreadID: child.rootThreadID, childThreadID: child.threadID,
        message: message, wireText: message.content, expectedTurnID: nil)
      try store.recordSubagentSubmission(pending)
      second.images.append(next); second.draft = "new input"
      return "turn"
    }
    XCTAssertTrue(sent); XCTAssertEqual(first.draft, "new input"); XCTAssertEqual(first.images, [next]); XCTAssertTrue(first.files.isEmpty)
    XCTAssertEqual(store.library.imageReferences[image.id], image); XCTAssertEqual(store.library.fileReferences[file.id], file)
    XCTAssertNoThrow(try ImageAttachmentStorage.data(image, root: store.dataRoot))
    XCTAssertNoThrow(try FileAttachmentStorage.text(file, root: store.dataRoot))
  }
}
