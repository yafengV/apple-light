import XCTest

@testable import ShipiOS

final class ConnectionTests: XCTestCase {
  func testSSHConfigListsOnlyExplicitAliasesAndPreservesOrder() {
    let config = """
      # workstation aliases
      Host devbox build-server
        HostName dev.example.com
      Host *.internal !blocked.internal
        User worker
      host devbox
      Host remote-workstation
      """
    XCTAssertEqual(
      SSHConfigParser.aliases(in: config),
      ["devbox", "build-server", "remote-workstation"])
  }

  func testResolvedOpenSSHOutputMapsDisplayFields() {
    let host = SSHConfigParser.resolved(
      alias: "devbox",
      output: """
        user ship
        hostname 10.0.0.8
        port 2222
        identityfile ~/.ssh/id_ed25519
        identityfile ~/.ssh/id_rsa
        """)
    XCTAssertEqual(host.alias, "devbox")
    XCTAssertEqual(host.destination, "ship@10.0.0.8")
    XCTAssertEqual(host.port, 2222)
    XCTAssertEqual(host.identityFiles.count, 2)
  }

  func testCatalogMissingFileIsEmptyAndRejectsOversizedInput() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertTrue(try SSHHostCatalog.load(configURL: root.appendingPathComponent("missing")).isEmpty)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let oversized = root.appendingPathComponent("config")
    try Data(repeating: 65, count: 2_097_153).write(to: oversized)
    XCTAssertThrowsError(try SSHHostCatalog.load(configURL: oversized))
  }

  @MainActor func testConnectionsStayInsideSettingsAndPreserveReturnPage() {
    let store = WorkspaceStore()
    store.draft = "connection draft"
    store.showAutomations()
    store.openSettings(.connections)
    XCTAssertEqual(store.destination, .settings)
    XCTAssertEqual(store.settingsPage, .connections)
    XCTAssertTrue(store.retainsAutomationsPage)
    store.closeSettings()
    XCTAssertEqual(store.destination, .automations)
    XCTAssertEqual(store.draft, "connection draft")
  }
}
