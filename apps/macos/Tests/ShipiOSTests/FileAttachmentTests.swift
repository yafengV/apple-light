import AppKit
import CoreText
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import ShipiOS

final class FileAttachmentTests: XCTestCase {
  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("file-attachment-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
  private func source(_ root: URL, name: String = "例子.swift", text: String = "let greeting = \"世界\"\n") throws -> URL {
    let url = root.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    return url
  }

  func testSnapshotSurvivesSourceRemovalAndRejectsTampering() throws {
    let root = try temporaryRoot()
    let original = try source(root)
    let attachment = try FileAttachmentStorage.importFile(original, root: root)
    try FileManager.default.removeItem(at: original)
    XCTAssertEqual(try FileAttachmentStorage.text(attachment, root: root), "let greeting = \"世界\"\n")
    let saved = FileAttachmentStorage.url(attachment, root: root)
    let permissions = try FileManager.default.attributesOfItem(atPath: saved.path)[.posixPermissions] as? Int
    XCTAssertEqual(permissions, 0o600)
    try Data("modified".utf8).write(to: saved)
    XCTAssertThrowsError(try FileAttachmentStorage.text(attachment, root: root))
  }

  func testBinaryOversizedAndSymlinkedAttachmentsAreRejected() throws {
    let root = try temporaryRoot()
    let invalid = root.appendingPathComponent("binary.zip")
    try Data([0, 1, 255, 3]).write(to: invalid)
    XCTAssertThrowsError(try FileAttachmentStorage.importFile(invalid, root: root))
    let large = try source(root, text: String(repeating: "x", count: FileAttachmentStorage.maxTextBytes + 1))
    XCTAssertThrowsError(try FileAttachmentStorage.importFile(large, root: root))
    let original = try source(root, text: "original")
    let attachment = try FileAttachmentStorage.importFile(original, root: root)
    let saved = FileAttachmentStorage.url(attachment, root: root)
    try FileManager.default.removeItem(at: saved)
    try FileManager.default.createSymbolicLink(at: saved, withDestinationURL: original)
    XCTAssertThrowsError(try FileAttachmentStorage.text(attachment, root: root))
  }

  func testUTF16AndPDFTextExtraction() throws {
    let root = try temporaryRoot()
    let utf = root.appendingPathComponent("unicode.txt")
    try XCTUnwrap("文字 😀".data(using: .utf16)).write(to: utf)
    let unicode = try FileAttachmentStorage.importFile(utf, root: root)
    XCTAssertEqual(try FileAttachmentStorage.text(unicode, root: root), "文字 😀")
    let data = NSMutableData()
    let consumer = try XCTUnwrap(CGDataConsumer(data: data))
    var box = CGRect(x: 0, y: 0, width: 300, height: 200)
    let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "PDF context text"))
    context.textPosition = CGPoint(x: 20, y: 100)
    CTLineDraw(line, context)
    context.endPDFPage(); context.closePDF()
    let pdf = root.appendingPathComponent("document.pdf")
    try (data as Data).write(to: pdf)
    let attached = try FileAttachmentStorage.importFile(pdf, root: root)
    XCTAssertTrue(attached.isPDF)
    XCTAssertTrue(try FileAttachmentStorage.text(attached, root: root).contains("PDF context text"))
  }

  func testWireIncludesFileTextWithImagesAndRejectsAggregateOverflow() throws {
    let root = try temporaryRoot()
    let file = try FileAttachmentStorage.importFile(source(root), root: root)
    let image = try ImageAttachmentStorage.importData(AttachmentFixture.png(), name: "test.png", root: root)
    let message = ChatMessage(role: "user", content: "review", images: [image], files: [file])
    let data = try ImageAttachmentStorage.requestData(config: .init(), messages: [message], root: root)
    let json = try JSONDecoder().decode(JSONValue.self, from: data)
    let parts = json["messages"].items[0]["content"].items
    XCTAssertTrue(parts[0]["text"].text?.contains("世界") == true)
    XCTAssertTrue(parts[0]["text"].text?.contains("例子.swift") == true)
    XCTAssertEqual(parts[1]["type"].text, "image_url")
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(root.path))
    let large = try FileAttachmentStorage.importFile(source(root, text: String(repeating: "a", count: 160_000)), root: root)
    XCTAssertThrowsError(try ImageAttachmentStorage.requestData(config: .init(),
      messages: [ChatMessage(role: "user", content: "", files: Array(repeating: large, count: 7))], root: root))
  }

  @MainActor func testImportDraftOwnershipPersistenceAndFailedBatchRollback() async throws {
    let root = try temporaryRoot()
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    let originalKey = store.draftKey
    let imported = await store.importFiles([try source(root)], draft: "other-task")
    XCTAssertTrue(imported)
    XCTAssertTrue(store.draftFiles.isEmpty)
    XCTAssertEqual(store.draftKey, originalKey)
    let file = try XCTUnwrap(store.library.draftFiles["other-task"]?.first)
    let restored = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertEqual(restored.draftFiles["other-task"], [file])
    let binary = root.appendingPathComponent("invalid.bin")
    try Data([0, 1, 2]).write(to: binary)
    let failed = await store.importFiles([try source(root), binary])
    XCTAssertFalse(failed)
    XCTAssertTrue(store.draftFiles.isEmpty)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("FileAttachments").path).count, 1)
    XCTAssertTrue(try JSONDecoder().decode(WorkspaceLibrary.self, from: Data("{}".utf8)).draftFiles.isEmpty)
    await store.shutdown()
  }

  @MainActor func testFileURLPasteProviderUsesCapturedDraftWithoutReadingClipboard() async throws {
    let root = try temporaryRoot()
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    let key = store.draftKey
    let url = try source(root)
    let provider = NSItemProvider(item: url.dataRepresentation as NSData, typeIdentifier: UTType.fileURL.identifier)
    store.pasteAttachments([provider])
    XCTAssertTrue(store.importingFiles)
    XCTAssertFalse(store.canSend)
    for _ in 0..<100 where store.importingFiles { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertFalse(store.importingFiles)
    XCTAssertEqual(store.library.draftFiles[key]?.first?.name, url.lastPathComponent)
    XCTAssertEqual(try FileAttachmentStorage.text(XCTUnwrap(store.draftFiles.first), root: root), "let greeting = \"世界\"\n")
    await store.shutdown()
  }

  @MainActor func testQueueEditForkAndLastReferenceCleanup() async throws {
    let root = try temporaryRoot()
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    let file = try FileAttachmentStorage.importFile(source(root), root: root)
    let run = AgentRun(id: "run", kind: "chat", project: "", status: "succeeded", createdAt: 1, updatedAt: 1, request: .null, result: nil)
    store.library.tasks = [.init(id: "task", project: "", title: "First", runIDs: ["run"])]
    store.library.chatRuns = [run]; store.runs = [run]; store.selection = "run"
    store.library.runFiles[run.id] = [file]
    let queued = QueuedMessage(taskID: "task", text: "queued", files: [file])
    store.library.queuedMessages = [queued]
    store.editQueuedMessage(queued)
    XCTAssertEqual(store.draftFiles, [file])
    XCTAssertEqual(store.draft, "queued")
    XCTAssertTrue(store.library.queuedMessages.isEmpty)
    let fork = try store.library.forkConversation(taskID: "task", availableRuns: [run])
    XCTAssertEqual(store.library.chatContext(taskID: fork.id).first?.files, [file])
    store.removeDraftFile(file)
    XCTAssertTrue(FileManager.default.fileExists(atPath: FileAttachmentStorage.url(file, root: root).path))
    var candidate = store.library
    candidate.runFiles = [:]
    try store.commitLibrary(candidate)
    XCTAssertFalse(FileManager.default.fileExists(atPath: FileAttachmentStorage.url(file, root: root).path))
    await store.shutdown()
  }

  @MainActor func testFailedSaveKeepsFileDraftAndDoesNotStartRequest() async throws {
    let root = try temporaryRoot()
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    let added = await store.importFiles([try source(root)])
    XCTAssertTrue(added)
    let files = store.draftFiles
    store.draft = "retain"
    store.modelConfiguration.baseURL = "http://127.0.0.1:1/v1"
    store.modelConfiguration.model = "fixture"
    let workspace = root.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: workspace)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    await store.sendDraft()
    XCTAssertEqual(store.draftFiles, files)
    XCTAssertEqual(store.draft, "retain")
    XCTAssertNil(store.modelTask)
    XCTAssertTrue(store.library.chatRuns.isEmpty)
    XCTAssertNotNil(store.error)
    await store.shutdown()
  }
}
