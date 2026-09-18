import XCTest

@testable import ShipiOS

final class AgentTests: XCTestCase {
  func testFragmentedUnicodeFramesAndMultipleMessages() throws {
    var decoder = FrameDecoder()
    let source = Data("{\"message\":\"你好\"}\n{\"id\":2}\n".utf8)
    var frames: [JSONValue] = []
    for byte in source { frames += try decoder.append(Data([byte])) }
    XCTAssertEqual(frames.count, 2)
    XCTAssertEqual(frames[0]["message"].text, "你好")
    XCTAssertEqual(frames[1]["id"].int, 2)
    XCTAssertTrue(decoder.buffer.isEmpty)
  }

  func testMalformedAndUnboundedFramesFail() {
    var decoder = FrameDecoder()
    XCTAssertThrowsError(try decoder.append(Data("not json\n".utf8)))
    decoder = FrameDecoder()
    XCTAssertThrowsError(try decoder.append(Data(repeating: 65, count: 16 * 1024 * 1024 + 1)))
  }

  func testRunDecodingKeepsTerminalAndMillisecondTimestamp() throws {
    let run = try JSONDecoder().decode(
      AgentRun.self,
      from: Data(
        """
        {"id":"r1","kind":"build","project":"/tmp/project","status":"cancelled",
         "createdAt":1700000000123,"updatedAt":1700000000456,
         "request":{"kind":"build","scheme":"Demo"},"result":null}
        """.utf8))
    XCTAssertFalse(run.isActive)
    XCTAssertEqual(run.date.timeIntervalSince1970, 1700000000.123, accuracy: 0.001)
    XCTAssertEqual(run.title, "构建 · Demo")
  }

  @MainActor func testRealAgentHandshakeInspectionErrorsAndReconnect() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let binary = repository.appendingPathComponent("target/debug/shipios-agent")
    XCTAssertTrue(
      FileManager.default.isExecutableFile(atPath: binary.path),
      "Build the Rust agent before swift test")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "shipios-swift-test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("Sample.xcodeproj"), withIntermediateDirectories: true)
    let client = AgentClient()
    do {
      try client.start(
        executable: binary, project: root, dataDirectory: root.appendingPathComponent("data"))
      let hello = try await client.request("initialize", ["protocolVersion": .number(1)])
      XCTAssertEqual(hello["capabilities"]["modelCalls"].boolean, false)
      let inspection = try await client.request("project.inspect").decode(ProjectInspection.self)
      XCTAssertEqual(inspection.containers, ["Sample.xcodeproj"])
      do {
        _ = try await client.request(
          "run.start",
          [
            "kind": .string("build"), "container": .string("../Outside.xcodeproj"),
            "scheme": .string("Demo"),
          ])
        XCTFail("An invalid project must be rejected")
      } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
      let runs = try await client.request("run.list").decode([AgentRun].self)
      XCTAssertTrue(runs.isEmpty)
      await client.stop()
      // Reconnecting to the exact same state directory proves the old process released its lock.
      try client.start(
        executable: binary, project: root, dataDirectory: root.appendingPathComponent("data"))
      _ = try await client.request("initialize", ["protocolVersion": .number(1)])
      await client.stop()
      do {
        _ = try await client.request("run.list")
        XCTFail("Disconnected request must fail")
      } catch { XCTAssertTrue(error.localizedDescription.contains("未连接")) }
    } catch {
      await client.stop()
      throw error
    }
  }
}
