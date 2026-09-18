import XCTest
@testable import ShipiOS

final class MCPConnectionTests: XCTestCase {
  private var fixture: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/mcp_server.py")
  }
  private func stdio(_ mode: String = "stdio", pidFile: URL? = nil) -> MCPServerConfiguration {
    var configuration = MCPServerConfiguration()
    configuration.name = "fixture"
    configuration.command = "/usr/bin/python3"
    configuration.arguments = ["-u", fixture.path, mode] + (pidFile.map { [$0.path] } ?? [])
    return configuration
  }
  private func httpServer() throws -> (Process, String) {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-u", fixture.path, "http"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard Int(port) != nil else { throw AgentFailure(message: "Fixture failed") }
    return (process, "http://127.0.0.1:\(port)")
  }

  @MainActor func testSTDIOHandshakePaginationEnvironmentIsolationAndProcessCleanup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let pidFile = root.appendingPathComponent("pid")
    var configuration = stdio(pidFile: pidFile)
    configuration.environment = [.init(key: "EXPLICIT", value: "explicit value")]
    configuration.environmentPassthrough = ["PASSTHROUGH"]
    let connection = try MCPConnection(configuration: configuration,
      environment: ["PASSTHROUGH": "passed", "CODEX_HOME": "not-inherited"])
    let tools = try await connection.initialize()
    XCTAssertEqual(tools.map(\.name), ["first", "second"])
    let environment = try JSONDecoder().decode(JSONValue.self, from: Data(tools[0].summary.utf8))
    XCTAssertEqual(environment["EXPLICIT"].text, "explicit value")
    XCTAssertEqual(environment["PASSTHROUGH"].text, "passed")
    XCTAssertEqual(environment["CODEX_HOME"], .null)
    XCTAssertEqual(connection.serverName, "Fixture")
    let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile)))
    await connection.close()
    XCTAssertNotEqual(kill(pid, 0), 0)
  }

  @MainActor func testHTTPJSONAndSSEHandshakeSessionHeadersAndTools() async throws {
    let (process, base) = try httpServer()
    defer { process.terminate(); process.waitUntilExit() }
    for path in ["/mcp", "/sse"] {
      var config = MCPServerConfiguration()
      config.name = "fixture"; config.transport = .streamableHTTP; config.url = base + path
      let connection = try MCPConnection(configuration: config, environment: [:])
      do {
        let tools = try await connection.initialize()
        XCTAssertEqual(tools.map(\.name), ["first", "second"])
        let refreshed = try await connection.listTools()
        XCTAssertEqual(refreshed.map(\.name), ["first", "second"])
      } catch { await connection.close(); throw error }
      await connection.close()
    }
  }

  @MainActor func testHTTPAuthorizationRedirectVersionAndDuplicateFailures() async throws {
    let (process, base) = try httpServer()
    defer { process.terminate(); process.waitUntilExit() }
    for path in ["/auth", "/redirect", "/version", "/duplicate"] {
      var config = MCPServerConfiguration()
      config.name = "fixture"; config.transport = .streamableHTTP; config.url = base + path
      let connection = try MCPConnection(configuration: config, environment: [:])
      do { _ = try await connection.initialize(); XCTFail("Should reject \(path)") }
      catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
      await connection.close()
    }
    var config = MCPServerConfiguration()
    config.name = "fixture"; config.transport = .streamableHTTP; config.url = base
    config.bearerTokenEnvironmentVariable = "MISSING"
    XCTAssertThrowsError(try MCPHTTPWire(configuration: config, environment: [:]))
    XCTAssertThrowsError(try MCPHTTPWire(configuration: config, environment: ["MISSING": "bad\r\nvalue"]))
  }

  @MainActor func testMalformedSTDIOAndTimeoutDoNotHang() async throws {
    for mode in ["malformed", "stall"] {
      let wire = try MCPStdioWire(configuration: stdio(mode), timeout: .milliseconds(300))
      let connection = MCPConnection(wire: wire)
      do { _ = try await connection.initialize(); XCTFail("Should fail \(mode)") }
      catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
      await connection.close()
    }
  }

  @MainActor func testStoreConnectDisableCancelAndEditInvalidateLateResults() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.loadMCPServers()
    let config = stdio()
    XCTAssertTrue(store.saveMCPServer(config))
    store.connectMCPServer(config.id)
    await store.mcpConnectionTasks[config.id]?.value
    XCTAssertEqual(store.mcpConnectionStates[config.id]?.tools.count, 2)
    XCTAssertTrue(store.setMCPServerEnabled(false, id: config.id))
    XCTAssertEqual(store.mcpConnectionStates[config.id], .disconnected)
    XCTAssertNil(store.mcpConnections[config.id])
    XCTAssertTrue(store.setMCPServerEnabled(true, id: config.id))
    await store.mcpConnectionTasks[config.id]?.value
    XCTAssertEqual(store.mcpConnectionStates[config.id]?.tools.count, 2)
    var changed = config
    changed.arguments = stdio("stall").arguments
    XCTAssertTrue(store.saveMCPServer(changed))
    XCTAssertEqual(store.mcpConnectionStates[config.id], .disconnected)
    store.connectMCPServer(config.id)
    let pending = store.mcpConnectionTasks[config.id]
    store.disconnectMCPServer(config.id)
    await pending?.value
    XCTAssertEqual(store.mcpConnectionStates[config.id], .disconnected)
    XCTAssertNil(store.mcpConnections[config.id])
    await store.shutdownMCPConnections()
  }
}
