import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import ShipiOS

@MainActor final class SubagentAttachmentTests: XCTestCase {
  private func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("child-attachments-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
  private func agent(_ child: String = "child") -> CodexSubagent {
    .init(rootThreadID: "root", threadID: child, status: .completed, loaded: true, observedAtMs: 0)
  }
  private func waitFor(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition() {
      guard ContinuousClock.now < deadline else { throw AgentFailure(message: "Attachment provider did not start") }
      await Task.yield()
    }
  }
  func testMixedImageAndTextImportsRemainOwnedByEachPanel() async throws {
    let root = try root(), file = root.appendingPathComponent("notes.txt")
    try Data("child reference".utf8).write(to: file)
    let first = SubagentDetailState(), second = SubagentDetailState()
    first.select(agent()); second.select(agent())
    let imported = await first.importAttachments([.image(try AttachmentFixture.png(), name: "screen.png"), .file(file)], root: root)
    XCTAssertTrue(imported); XCTAssertTrue(first.hasInput); XCTAssertEqual(first.images.count, 1); XCTAssertEqual(first.files.count, 1)
    XCTAssertFalse(second.hasInput); XCTAssertTrue(second.images.isEmpty); XCTAssertTrue(second.files.isEmpty)
    XCTAssertEqual(try FileAttachmentStorage.text(first.files[0], root: root), "child reference")
    let image = try ImageAttachmentStorage.storedImage(path: ImageAttachmentStorage.url(first.images[0], root: root).resolvingSymlinksInPath().path, root: root)
    XCTAssertEqual(image.id, first.images[0].id)
    first.select(nil); XCTAssertFalse(first.hasInput); XCTAssertFalse(first.importing)
  }
  func testFailedMixedBatchAndCountOverflowRollBackOnlyNewCopies() async throws {
    let root = try root(), state = SubagentDetailState(); state.select(agent())
    let imported = await state.importAttachments([.image(try AttachmentFixture.png(), name: "existing.png")], root: root)
    XCTAssertTrue(imported)
    let original = state.images
    let failed = await state.importAttachments([.image(try AttachmentFixture.png(), name: "new.png"), .image(Data("bad image".utf8), name: "broken")], root: root)
    XCTAssertFalse(failed); XCTAssertEqual(state.images, original); XCTAssertNotNil(state.attachmentError)
    let png = try AttachmentFixture.png()
    let overflow = await state.importAttachments((0..<8).map { _ in .image(png, name: "extra.png") }, root: root)
    XCTAssertFalse(overflow); XCTAssertEqual(state.images, original)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Attachments").path).count, 1)
  }
  func testSelectionChangingDuringProviderReadCannotImportIntoNewChild() async throws {
    let root = try root(), state = SubagentDetailState(); state.select(agent("old"))
    let provider = NSItemProvider()
    var reply: ((Data?, Error?) -> Void)?
    provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
      Task { @MainActor in reply = completion }; return nil
    }
    let importing = Task { await state.importProviders([provider], root: root) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while reply == nil { guard ContinuousClock.now < deadline else { XCTFail("Provider did not start"); return }; await Task.yield() }
    XCTAssertTrue(state.importing)
    state.select(agent("new")); state.draft = "new child draft"
    reply?(try AttachmentFixture.png(), nil)
    let accepted = await importing.value
    XCTAssertFalse(accepted); XCTAssertEqual(state.selected?.threadID, "new"); XCTAssertEqual(state.draft, "new child draft")
    XCTAssertTrue(state.images.isEmpty); XCTAssertFalse(state.importing)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Attachments").path))
  }
  func testAttachmentOnlySendRetainsFailedInputAndClearsOnlyAcknowledgedSnapshot() async throws {
    let root = try root(), state = SubagentDetailState(); state.select(agent())
    let imported = await state.importAttachments([.image(try AttachmentFixture.png(), name: "only.png")], root: root)
    XCTAssertTrue(imported)
    let original = state.images
    let failed = await state.sendMessage(working: false) { _, message, turn in
      XCTAssertEqual(message.images, original); XCTAssertEqual(message.content, ""); XCTAssertNil(turn)
      throw AgentFailure(message: "Offline")
    }
    XCTAssertFalse(failed); XCTAssertEqual(state.images, original); XCTAssertNotNil(state.error)
    let next = try ImageAttachmentStorage.importData(try AttachmentFixture.png(), name: "next.png", root: root)
    let sent = await state.sendMessage(working: false) { _, _, _ in
      state.draft = "next draft"; state.images.append(next); return "accepted-turn"
    }
    XCTAssertTrue(sent); XCTAssertEqual(state.draft, "next draft"); XCTAssertEqual(state.images, [next]); XCTAssertNil(state.error)
    var usedTextOnlyAPI = false
    let legacy = await state.send(working: false) { _, _, _ in usedTextOnlyAPI = true; return "turn" }
    XCTAssertFalse(legacy); XCTAssertFalse(usedTextOnlyAPI, "A legacy text-only callback must not drop images")
  }
  func testClearingDuringImportAllowsAnotherImportAndRejectsBothLateCompletions() async throws {
    let root = try root(), state = SubagentDetailState(); state.select(agent())
    var callbacks: [Int: (Data?, Error?) -> Void] = [:]
    func provider(_ index: Int) -> NSItemProvider {
      let provider = NSItemProvider()
      provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
        Task { @MainActor in callbacks[index] = completion }; return nil
      }
      return provider
    }
    let first = Task { await state.importProviders([provider(0)], root: root) }
    try await waitFor { callbacks[0] != nil }
    state.clearDraft(); XCTAssertFalse(state.importing)
    let second = Task { await state.importProviders([provider(1)], root: root) }
    try await waitFor { callbacks[1] != nil }
    callbacks[0]?(try AttachmentFixture.png(), nil)
    let oldAccepted = await first.value
    XCTAssertFalse(oldAccepted); XCTAssertTrue(state.images.isEmpty); XCTAssertTrue(state.importing)
    callbacks[1]?(try AttachmentFixture.png(), nil)
    let newAccepted = await second.value
    XCTAssertTrue(newAccepted); XCTAssertFalse(state.importing); XCTAssertEqual(state.images.count, 1)
  }
  func testProviderTimeoutAndCancellationReleaseLoadingWithoutDroppingDraft() async throws {
    let root = try root(), state = SubagentDetailState(); state.select(agent()); state.draft = "keep draft"
    var callback: ((Data?, Error?) -> Void)?
    func provider() -> NSItemProvider {
      let provider = NSItemProvider()
      provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
        Task { @MainActor in callback = completion }; return Progress(totalUnitCount: 1)
      }
      return provider
    }
    let timedOut = await state.importProviders([provider()], root: root, timeout: .milliseconds(50))
    XCTAssertFalse(timedOut); XCTAssertFalse(state.importing)
    XCTAssertTrue(state.attachmentError?.contains("超时") == true); XCTAssertEqual(state.draft, "keep draft")
    callback?(try AttachmentFixture.png(), nil)
    callback = nil
    let pending = Task { await state.importProviders([provider()], root: root) }
    try await waitFor { callback != nil }
    pending.cancel()
    let cancelled = await pending.value
    XCTAssertFalse(cancelled); XCTAssertFalse(state.importing); XCTAssertNil(state.attachmentError)
    callback?(try AttachmentFixture.png(), nil)
    XCTAssertTrue(state.images.isEmpty); XCTAssertEqual(state.draft, "keep draft")
  }
  func testNativeImageOnlyHistoryIsNotDroppedOrDuplicatedAndForeignFilesAreRejected() throws {
    let root = try root(), original = try ImageAttachmentStorage.importData(try AttachmentFixture.png(), name: "owned.png", root: root)
    let path = ImageAttachmentStorage.url(original, root: root).resolvingSymlinksInPath().path
    let legacy: JSONValue = .object(["type": .string("user_message"), "message": .string(""), "local_images": .array([.string(path)])])
    let item: JSONValue = .object(["type": .string("item_completed"), "item": .object(["type": .string("UserMessage"), "content": .array([
      .object(["type": .string("local_image"), "path": .string(path)])])])])
    let transcript = SubagentTranscript(events: [legacy, item])
    XCTAssertEqual(transcript.entries.count, 1); XCTAssertEqual(transcript.entries.first?.localImagePaths, [path])
    XCTAssertEqual(SubagentTranscript(events: [item]).entries.first?.localImagePaths, [path])
    let foreign = root.appendingPathComponent("outside.png"); try AttachmentFixture.png().write(to: foreign)
    XCTAssertThrowsError(try ImageAttachmentStorage.storedImage(path: foreign.path, root: root))
    let link = root.appendingPathComponent("Attachments/\(UUID()).png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: foreign)
    XCTAssertThrowsError(try ImageAttachmentStorage.storedImage(path: link.path, root: root))
  }
  func testImageImportsRejectRedirectedAttachmentDirectory() throws {
    let root = try root(), elsewhere = root.appendingPathComponent("elsewhere")
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Attachments"), withDestinationURL: elsewhere)
    XCTAssertThrowsError(try ImageAttachmentStorage.importData(try AttachmentFixture.png(), name: "image.png", root: root))
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
  }
  func testChildAttachmentComposerRendersAtNarrowAndWideWidthsAndOwnsClearCommand() async throws {
    _ = NSApplication.shared
    let root = try root(), store = WorkspaceStore(dataRoot: root), state = SubagentDetailState()
    state.select(agent())
    let file = root.appendingPathComponent("narrow.txt"); try Data("reference".utf8).write(to: file)
    let imported = await state.importAttachments([.image(try AttachmentFixture.png(), name: "preview.png"), .file(file)], root: root)
    XCTAssertTrue(imported)
    for width in [320.0, 760.0] {
      let view = SubagentComposerView(text: .init(get: { state.draft }, set: { state.draft = $0 }), plainTextMode: true,
        sendShortcut: .commandEnter, working: false, sending: false, stopping: false, canSend: state.hasInput,
        canStop: false, stopError: nil, previousPrompt: nil, send: {}, stop: {}, store: store, detail: state)
      let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: 280),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      defer { window.close() }
      let host = NSHostingView(rootView: view); window.contentView = host; host.layoutSubtreeIfNeeded()
      func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
      let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? ComposerNativeTextView }.first)
      XCTAssertEqual(editor.string, "")
      XCTAssertTrue(window.makeFirstResponder(editor))
      let context = try XCTUnwrap(ComposerCommandContext.focused(in: window))
      XCTAssertTrue(context.enabled.contains("clear-prompt"))
      XCTAssertTrue(context.enabled.isSuperset(of: ["add-photos", "add-files"]))
      XCTAssertGreaterThan(host.fittingSize.height, 150)
      XCTAssertLessThanOrEqual(host.fittingSize.width, width + 1)
      if width == 760 { XCTAssertTrue(context.execute("clear-prompt")); XCTAssertFalse(state.hasInput) }
    }
  }
}
