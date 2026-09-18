import XCTest
@testable import ShipiOS

final class MCPServerSettingsTests: XCTestCase {
  private func root() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }
  private func stdio() -> MCPServerConfiguration {
    var server = MCPServerConfiguration()
    server.name = "local-server"
    server.command = "/usr/bin/example"
    server.arguments = ["--path", "/folder with spaces/database"]
    server.environment = [MCPKeyValue(key: "TOKEN", value: "value with spaces")]
    server.environmentPassthrough = ["PATH", "SDK_ROOT"]
    server.workingDirectory = "~/Projects"
    return server
  }
  private func http() -> MCPServerConfiguration {
    var server = MCPServerConfiguration()
    server.name = "remote-server"
    server.transport = .streamableHTTP
    server.url = "https://example.com/mcp"
    server.bearerTokenEnvironmentVariable = "MCP_TOKEN"
    server.headers = [MCPKeyValue(key: "X-Project", value: "sample")]
    server.environmentHeaders = [MCPKeyValue(key: "X-Account", value: "ACCOUNT_ID")]
    return server
  }

  func testBothTransportsRoundTripWithPrivatePermissions() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertTrue(try MCPServerStorage.load(root: root).isEmpty)
    var servers = [stdio(), http()]
    try MCPServerStorage.save(servers, root: root)
    XCTAssertEqual(try MCPServerStorage.load(root: root), servers)
    servers[0].enabled = false
    servers[1].headers[0].value = "edited"
    try MCPServerStorage.save(servers, root: root)
    XCTAssertEqual(try MCPServerStorage.load(root: root), servers)
    let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("mcp-servers.json").path)
    XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["mcp-servers.json"])
  }

  func testValidationRejectsDuplicatesAndInvalidHTTPHeadersWithoutOverwrite() throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = [stdio(), http()]
    try MCPServerStorage.save(original, root: root)
    var duplicate = stdio()
    duplicate.name = "LOCAL-SERVER"
    XCTAssertThrowsError(try MCPServerStorage.save(original + [duplicate], root: root))
    for url in ["file:///tmp/server", "https://user:password@example.com/mcp", "https://example.com/#fragment", "localhost"] {
      var server = http(); server.url = url
      XCTAssertThrowsError(try server.validated())
    }
    var server = http()
    server.headers.append(MCPKeyValue(key: "x-project", value: "duplicate"))
    XCTAssertThrowsError(try server.validated())
    server = http(); server.headers[0].value = "one\r\nInjected: two"
    XCTAssertThrowsError(try server.validated())
    server = http(); server.environmentHeaders[0].value = "not a variable"
    XCTAssertThrowsError(try server.validated())
    server = http(); server.headers.append(MCPKeyValue(key: "Authorization", value: "Bearer second"))
    XCTAssertThrowsError(try server.validated())
    XCTAssertEqual(try MCPServerStorage.load(root: root), original)
  }

  func testSTDIOValidationPreservesArgumentsAndRejectsInvalidEnvironment() throws {
    var server = stdio()
    XCTAssertEqual(try server.validated().arguments, server.arguments)
    server.command = " "
    XCTAssertThrowsError(try server.validated())
    server = stdio(); server.environment.append(MCPKeyValue(key: "TOKEN", value: "duplicate"))
    XCTAssertThrowsError(try server.validated())
    server = stdio(); server.environment[0].key = "1BAD"
    XCTAssertThrowsError(try server.validated())
    server = stdio(); server.environmentPassthrough.append("PATH")
    XCTAssertThrowsError(try server.validated())
    server = stdio(); server.arguments = [String(repeating: "x", count: 70_000)]
    XCTAssertThrowsError(try server.validated())
  }

  @MainActor func testEditorStateTracksValidChangesAndDuplicateNames() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.loadMCPServers()
    XCTAssertFalse(store.mcpServerEditState(MCPServerConfiguration()).canSave)
    let original = stdio()
    XCTAssertEqual(store.mcpServerEditState(original), .ready)
    XCTAssertTrue(store.saveMCPServer(original))
    XCTAssertEqual(store.mcpServerEditState(original), .unchanged)
    var edited = original
    edited.command = " /usr/bin/example "
    edited.environment[0].id = UUID()
    edited.environmentPassthrough.reverse()
    edited.url = "https://unused.example.com"
    XCTAssertEqual(store.mcpServerEditState(edited), .unchanged)
    edited.arguments.append("--new")
    XCTAssertEqual(store.mcpServerEditState(edited), .ready)
    edited.command = " "
    XCTAssertNotNil(store.mcpServerEditState(edited).validationMessage)
    var duplicate = original
    duplicate.id = UUID()
    XCTAssertNotNil(store.mcpServerEditState(duplicate).validationMessage)
    XCTAssertFalse(store.saveMCPServer(duplicate))
    XCTAssertEqual(store.mcpServers, [original])
  }

  @MainActor func testUnchangedSaveDoesNotRewriteFileAndHTTPComparisonUsesHeaderSemantics() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.loadMCPServers()
    let original = http()
    XCTAssertTrue(store.saveMCPServer(original))
    let file = root.appendingPathComponent("mcp-servers.json")
    let timestamp = Date(timeIntervalSince1970: 1_000_000)
    try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path)
    var equivalent = original
    equivalent.url = " " + original.url + " "
    equivalent.headers[0].id = UUID()
    equivalent.headers[0].key = "x-project"
    equivalent.command = "unused-command"
    XCTAssertEqual(store.mcpServerEditState(equivalent), .unchanged)
    XCTAssertTrue(store.saveMCPServer(equivalent))
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, timestamp)
    XCTAssertEqual(store.mcpServers, [original])
    equivalent.headers[0].value = "changed-value"
    XCTAssertEqual(store.mcpServerEditState(equivalent), .ready)
    XCTAssertTrue(store.saveMCPServer(equivalent))
    XCTAssertEqual(try MCPServerStorage.load(root: root).first?.headers[0].value, "changed-value")
  }

  @MainActor func testPageEditorBackSaveToggleReloadAndUninstallPreserveWorkspace() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.loadMCPServers()
    store.draft = "原草稿"
    store.showProjects()
    store.openSettings(.mcpServers)
    store.pluginSettingsQuery = "local"
    store.openMCPServerEditor()
    XCTAssertEqual(store.destination, .settings)
    XCTAssertEqual(store.settingsPage, .plugins)
    XCTAssertNotNil(store.mcpServerEditor)
    await store.navigate(back: true)
    XCTAssertNil(store.mcpServerEditor)
    XCTAssertEqual(store.destination, .settings)
    XCTAssertEqual(store.pluginSettingsQuery, "local")
    store.openMCPServerEditor()
    let server = stdio()
    XCTAssertTrue(store.saveMCPServer(server))
    XCTAssertNil(store.mcpServerEditor)
    XCTAssertEqual(store.mcpServers, [server])
    XCTAssertTrue(store.setMCPServerEnabled(false, id: server.id))
    await store.loadMCPServers()
    XCTAssertFalse(try XCTUnwrap(store.mcpServers.first).enabled)
    store.openMCPServerEditor(server.id)
    XCTAssertEqual(store.mcpServerEditor?.id, server.id)
    XCTAssertTrue(store.removeMCPServer(server.id))
    XCTAssertNil(store.mcpServerEditor)
    XCTAssertTrue(store.mcpServers.isEmpty)
    XCTAssertTrue(try MCPServerStorage.load(root: root).isEmpty)
    store.closeSettings()
    XCTAssertEqual(store.destination, .projects)
    XCTAssertEqual(store.draft, "原草稿")
    XCTAssertTrue(store.library.tasks.isEmpty)
    XCTAssertNil(store.modelTask)
  }

  @MainActor func testFailedSaveKeepsEditorAndExistingConfiguration() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.loadMCPServers()
    store.openSettings(.mcpServers)
    store.openMCPServerEditor()
    let editorID = store.mcpServerEditor?.id
    XCTAssertFalse(store.saveMCPServer(MCPServerConfiguration()))
    XCTAssertEqual(store.mcpServerEditor?.id, editorID)
    XCTAssertNotNil(store.mcpServersError)
    let server = stdio()
    XCTAssertTrue(store.saveMCPServer(server))
    store.openMCPServerEditor(server.id)
    var changed = server
    changed.transport = .streamableHTTP
    changed.url = "https://example.com/mcp"
    XCTAssertFalse(store.saveMCPServer(changed))
    XCTAssertEqual(store.mcpServerEditor?.id, server.id)
    XCTAssertEqual(store.mcpServers, [server])
    let file = root.appendingPathComponent("mcp-servers.json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    try Data("block".utf8).write(to: file.appendingPathComponent("block"))
    XCTAssertFalse(store.setMCPServerEnabled(false, id: server.id))
    XCTAssertTrue(store.mcpServers[0].enabled)
    XCTAssertFalse(store.removeMCPServer(server.id))
    XCTAssertEqual(store.mcpServerEditor?.id, server.id)
  }

  @MainActor func testSwitchingSettingsCancelsEditorAndCorruptStorageDoesNotOverwrite() async throws {
    let root = root()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.loadMCPServers()
    store.openSettings(.mcpServers)
    store.openMCPServerEditor()
    store.settingsPage = .appearance
    XCTAssertNil(store.mcpServerEditor)
    store.openSettings(.mcpServers)
    store.openMCPServerEditor()
    store.revealSetting(SettingsSearchResult(page: .plugins, field: .mcpImport))
    XCTAssertNil(store.mcpServerEditor)
    XCTAssertEqual(store.settingsSearchRequest?.result.field, .mcpImport)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("mcp-servers.json")
    try Data("invalid".utf8).write(to: file)
    await store.loadMCPServers()
    XCTAssertFalse(store.mcpServersLoaded)
    XCTAssertFalse(store.saveMCPServer(stdio()))
    XCTAssertEqual(try String(contentsOf: file), "invalid")
    store.openMCPServerEditor()
    XCTAssertNil(store.mcpServerEditor)
  }
}
