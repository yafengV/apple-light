import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import ShipiOS

enum AttachmentFixture {
  static func png() throws -> Data {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 2, height: 2, bitsPerComponent: 8,
        bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    let image = try XCTUnwrap(context.makeImage())
    let data = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
  }
}

final class ImageAttachmentTests: XCTestCase {
  @MainActor func testPastedImageIsImportedWithoutReadingTheUserPasteboard() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    let data = try AttachmentFixture.png()
    let provider = NSItemProvider(item: data as NSData, typeIdentifier: UTType.png.identifier)
    store.pasteImages([provider])
    XCTAssertTrue(store.importingImages)
    XCTAssertFalse(store.canSend)
    for _ in 0..<100 where store.importingImages { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertFalse(store.importingImages)
    let image = try XCTUnwrap(store.draftImages.first)
    XCTAssertEqual(try ImageAttachmentStorage.data(image, root: root), data)
    XCTAssertTrue(store.canSend)
  }

  func testNativeTIFFClipboardRepresentationIsConvertedToPNG() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try XCTUnwrap(CGImageSourceCreateWithData(try AttachmentFixture.png() as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let imported = try ImageAttachmentStorage.importData(data as Data, name: "clipboard.tiff", root: root)
    XCTAssertEqual(imported.mimeType, "image/png")
    let bytes = try ImageAttachmentStorage.data(imported, root: root)
    XCTAssertEqual(Array(bytes.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
  }

  @MainActor func testRemovingImageOnlyDeletesPrivateCopyAfterLastReference() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    let imported = await store.importImages([.bytes(try AttachmentFixture.png(), name: "screen.png")])
    XCTAssertTrue(imported)
    let image = try XCTUnwrap(store.draftImages.first)
    let file = ImageAttachmentStorage.url(image, root: root)
    let queue = QueuedMessage(taskID: "task", text: "pending", images: [image])
    store.library.queuedMessages = [queue]
    store.removeDraftImage(image)
    XCTAssertTrue(store.draftImages.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    store.removeQueuedMessage(queue.id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
  }

  func testImportedSnapshotSurvivesSourceRemovalAndRejectsTampering() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let input = root.appendingPathComponent("screen.png")
    let data = try AttachmentFixture.png()
    try data.write(to: input)
    let image = try ImageAttachmentStorage.importFile(input, root: root)
    try FileManager.default.removeItem(at: input)
    XCTAssertEqual(try ImageAttachmentStorage.data(image, root: root), data)
    XCTAssertEqual(image.mimeType, "image/png")
    XCTAssertEqual(try ImageAttachmentStorage.thumbnail(image, root: root, size: 120).width, 2)
    let saved = ImageAttachmentStorage.url(image, root: root)
    let attributes = try FileManager.default.attributesOfItem(atPath: saved.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    try Data("changed".utf8).write(to: saved)
    XCTAssertThrowsError(try ImageAttachmentStorage.data(image, root: root))
  }

  func testWireRequestHasRealImageBytesAndNoLocalPaths() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let png = try AttachmentFixture.png()
    let image = try ImageAttachmentStorage.importData(png, name: "screen.png", root: root)
    let body = try ImageAttachmentStorage.requestData(
      config: .init(),
      messages: [
        .init(role: "system", content: "instructions"),
        .init(role: "user", content: "inspect", images: [image]),
      ], root: root)
    let value = try JSONDecoder().decode(JSONValue.self, from: body)
    XCTAssertEqual(value["messages"].items[0]["content"].text, "instructions")
    let parts = value["messages"].items[1]["content"].items
    XCTAssertEqual(parts[0]["type"].text, "text")
    XCTAssertEqual(parts[0]["text"].text, "inspect")
    XCTAssertEqual(parts[1]["type"].text, "image_url")
    XCTAssertEqual(
      parts[1]["image_url"]["url"].text, "data:image/png;base64," + png.base64EncodedString())
    XCTAssertFalse(String(decoding: body, as: UTF8.self).contains(root.path))
    XCTAssertThrowsError(
      try ImageAttachmentStorage.requestData(
        config: .init(),
        messages: [
          .init(role: "user", content: "inspect", images: [image])
        ], root: nil))
  }

  func testInvalidOversizedAndLinkedAttachmentFilesAreRejected() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertThrowsError(
      try ImageAttachmentStorage.importData(Data("not an image".utf8), name: "fake.png", root: root)
    )
    XCTAssertThrowsError(
      try ImageAttachmentStorage.importData(
        Data(count: ImageAttachmentStorage.maxBytes + 1), name: "large.png", root: root))
    let image = try ImageAttachmentStorage.importData(
      AttachmentFixture.png(), name: "image.png", root: root)
    let saved = ImageAttachmentStorage.url(image, root: root)
    let replacement = root.appendingPathComponent("other.png")
    try FileManager.default.moveItem(at: saved, to: replacement)
    try FileManager.default.createSymbolicLink(at: saved, withDestinationURL: replacement)
    XCTAssertThrowsError(try ImageAttachmentStorage.data(image, root: root))
  }

  func testLegacyQueueAndLibraryDecodeWithoutAttachments() throws {
    let oldQueue = "{\"id\":\"\(UUID())\",\"taskID\":\"task\",\"text\":\"hello\"}"
    XCTAssertTrue(
      try JSONDecoder().decode(QueuedMessage.self, from: Data(oldQueue.utf8)).images.isEmpty)
    let library = try JSONDecoder().decode(WorkspaceLibrary.self, from: Data("{}".utf8))
    XCTAssertTrue(library.draftImages.isEmpty)
    XCTAssertTrue(library.runImages.isEmpty)
  }

  @MainActor func testDraftImportOwnershipPersistenceAndAtomicBatchFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    let data = try AttachmentFixture.png()
    let imported = await store.importImages([.bytes(data, name: "screen.png")], draft: "other-task")
    XCTAssertTrue(imported)
    XCTAssertTrue(store.draftImages.isEmpty)
    XCTAssertEqual(store.library.draftImages["other-task"]?.count, 1)
    let before = try FileManager.default.contentsOfDirectory(
      atPath: root.appendingPathComponent("Attachments").path)
    let failed = await store.importImages([
      .bytes(data, name: "valid.png"), .bytes(Data(), name: "invalid.png"),
    ])
    XCTAssertFalse(failed)
    XCTAssertTrue(store.draftImages.isEmpty)
    let after = try FileManager.default.contentsOfDirectory(
      atPath: root.appendingPathComponent("Attachments").path)
    XCTAssertEqual(Set(before), Set(after))
    let restored = WorkspaceStore(dataRoot: root)
    await restored.restore()
    XCTAssertEqual(
      restored.library.draftImages["other-task"], store.library.draftImages["other-task"])
  }

  @MainActor func testQueueEditAndForkKeepImagesAndDoNotCopyUnsentAttachments() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    let image = try ImageAttachmentStorage.importData(
      AttachmentFixture.png(), name: "screen.png", root: root)
    let run = AgentRun(
      id: "source", kind: "chat", project: "", status: "succeeded",
      createdAt: 0, updatedAt: 1, request: .null, result: .object(["response": .string("reply")]))
    store.library.chatRuns = [run]
    store.runs = [run]
    store.library.attach(run, to: nil, note: "image prompt")
    store.library.runImages[run.id] = [image]
    store.selection = run.id
    let queued = QueuedMessage(taskID: run.id, text: "next", images: [image])
    store.library.queuedMessages = [queued]
    store.editQueuedMessage(queued)
    XCTAssertEqual(store.draftImages, [image])
    XCTAssertEqual(store.draft, "next")
    XCTAssertTrue(store.library.queuedMessages.isEmpty)
    let fork = try XCTUnwrap(store.forkConversation())
    XCTAssertTrue(store.draftImages.isEmpty)
    XCTAssertEqual(store.library.draftImages[run.id], [image])
    XCTAssertEqual(store.library.chatContext(taskID: fork.id).first?.images, [image])
    XCTAssertEqual(try ImageAttachmentStorage.data(image, root: root), try AttachmentFixture.png())
  }

  @MainActor func testFailedSaveDoesNotConsumeDraftOrDeleteItsImage() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    let added = await store.importImages([.bytes(try AttachmentFixture.png(), name: "screen.png")])
    XCTAssertTrue(added)
    store.draft = "keep this"
    let images = store.draftImages
    store.modelConfiguration.baseURL = "http://127.0.0.1:1/v1"
    store.modelConfiguration.model = "fixture"
    let file = root.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    await store.sendDraft()
    XCTAssertEqual(store.draft, "keep this")
    XCTAssertEqual(store.draftImages, images)
    XCTAssertTrue(store.library.chatRuns.isEmpty)
    XCTAssertNil(store.modelTask)
    XCTAssertNotNil(store.error)
  }
}
