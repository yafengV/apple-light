import Foundation
import XCTest
@testable import ShipiOS

final class InitCommandTests: XCTestCase {
  func testInitRequiresProjectCodexRuntimeAndEmptyAttachments() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertThrowsError(try InitCommand.preparedPrompt(project: "", protocol: .codexResponses,
      hasAttachmentsOrComments: false))
    XCTAssertThrowsError(try InitCommand.preparedPrompt(project: "relative/project", protocol: .codexResponses,
      hasAttachmentsOrComments: false))
    XCTAssertThrowsError(try InitCommand.preparedPrompt(project: root.path, protocol: .chatCompletions,
      hasAttachmentsOrComments: false))
    XCTAssertThrowsError(try InitCommand.preparedPrompt(project: root.path, protocol: .codexResponses,
      hasAttachmentsOrComments: true))
    XCTAssertThrowsError(try InitCommand.preparedPrompt(project: root.path, protocol: .codexResponses,
      hasAttachmentsOrComments: false, isSideChat: true))
    XCTAssertEqual(try InitCommand.preparedPrompt(project: root.path, protocol: .codexResponses,
      hasAttachmentsOrComments: false), InitCommand.prompt)
    try Data("existing guide".utf8).write(to: root.appendingPathComponent("AGENTS.md"))
    XCTAssertThrowsError(try InitCommand.preparedPrompt(project: root.path, protocol: .codexResponses,
      hasAttachmentsOrComments: false))
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("AGENTS.md")), "existing guide")
    try FileManager.default.removeItem(at: root.appendingPathComponent("AGENTS.md"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("AGENTS.md"),
      withDestinationURL: root.appendingPathComponent("missing-guide"))
    XCTAssertThrowsError(try InitCommand.preparedPrompt(project: root.path, protocol: .codexResponses,
      hasAttachmentsOrComments: false))
  }

  @MainActor func testInitAppearsInComposerAndTaskOwnedCommandPalette() {
    XCTAssertEqual(ComposerCommand.initGuide.token, "/init")
    XCTAssertEqual(ComposerCommand.initGuide.actionID, "init")
    XCTAssertEqual(DesktopCommand.all.first { $0.id == "init" }?.group, .chat)
    XCTAssertTrue(TaskWindowCommandContext.owns("init"))
    var selection = ComposerCommandSelection()
    selection.update(draft: "/ini", enabled: [.initGuide])
    XCTAssertEqual(selection.matches, [.initGuide])
  }

  @MainActor func testCommandMenuDoesNotReplaceAnUnsentDraft() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"))
    store.project = root
    store.modelConfiguration.apiProtocol = .codexResponses
    store.draft = "Keep this unsent message"
    store.executeCommand("init")
    XCTAssertEqual(store.draft, "Keep this unsent message")
    XCTAssertTrue(store.error?.contains("清空当前草稿") == true)
  }
}
