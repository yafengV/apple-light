import Foundation
import XCTest

@testable import ShipiOS

final class CounterDeliveryIntegrationTests: XCTestCase {
  @MainActor func testNativeUIFailuresUseExactlyTwoCoreRepairsAndRemainTakeoverReady() async throws {
    var repo = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { repo.deleteLastPathComponent() }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("counter-loop-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("Project")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: repo.appendingPathComponent("fixtures/HelloShipiOS"), to: project)
    let source = """
      import SwiftUI
      @main struct HelloShipiOSApp: App {
        @State private var count = 0
        var body: some Scene {
          WindowGroup { VStack {
            Text(String(count)).accessibilityIdentifier("counter.value")
            Button("Increment") { count += 2 }.accessibilityIdentifier("counter.increment")
            Button("Reset") { count = 0 }.accessibilityIdentifier("counter.reset")
          } }
        }
      }
      """
    try source.write(to: project.appendingPathComponent("HelloShipiOSApp.swift"), atomically: true, encoding: .utf8)
    let server = Process(), pipe = Pipe()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = ["-u", repo.appendingPathComponent("apps/macos/Tests/Fixtures/model_server.py").path]
    server.standardOutput = pipe; server.standardError = FileHandle.nullDevice
    try server.run()
    defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
    let port = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertNotNil(Int(port))
    let store = WorkspaceStore(dataRoot: root.appendingPathComponent("Data"), agentExecutable: try AgentTestExecutable.url())
    await store.restore()
    var config = ModelConfiguration()
    config.baseURL = "http://127.0.0.1:\(port)/v1"; config.model = "gpt-5.4"; config.apiProtocol = .codexResponses
    try store.saveModelConfiguration(config)
    let task = WorkspaceTask(id: UUID().uuidString, project: project.path, title: "Controlled counter repair budget", runIDs: [])
    store.library.projects.append(project.path); store.library.tasks.append(task)
    XCTAssertTrue(store.canRepairCounter(taskID: task.id))
    store.beginCounterDelivery(taskID: task.id, repairFailures: true)
    guard let operation = store.counterDeliveryTasks[task.id] else {
      XCTFail(store.error ?? "Counter workflow not started"); await store.shutdown(); return
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(480))
    while store.counterDeliveryTasks[task.id] != nil && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(250))
    }
    if store.counterDeliveryTasks[task.id] != nil {
      operation.cancel(); await operation.value
      XCTFail("Counter repair integration exceeded 480 seconds")
    }
    let record = try XCTUnwrap(store.library.counterDeliveries[task.id])
    XCTAssertEqual(record.phase, .failed, record.message)
    XCTAssertEqual(record.repairs, 2); XCTAssertEqual(record.modelRunIDs.count, 2)
    XCTAssertEqual(record.verifications.count, 3)
    for result in record.verifications {
      XCTAssertEqual(result.status, "failed")
      XCTAssertEqual(result.result?["verification"].text, "failed")
      XCTAssertEqual(result.result?["testSummary"]["totalTestCount"].int, 1)
      XCTAssertEqual(result.result?["testSummary"]["failedTests"].int, 1)
      XCTAssertEqual(result.result?["testSummary"]["skippedTests"].int, 0)
    }
    XCTAssertEqual(record.modelRunIDs.compactMap { id in store.library.chatRuns.first(where: { $0.id == id })?.status }, ["succeeded", "succeeded"])
    XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("HelloShipiOSApp.swift")), source)
    XCTAssertTrue(store.canVerifyCounter(taskID: task.id))
    let saved = try JSONDecoder().decode(CounterDelivery.self,
      from: Data(contentsOf: root.appendingPathComponent("Data/CounterReports/\(record.id.uuidString).json")))
    XCTAssertEqual(saved, record)
    // Preserve only fixture evidence when explicitly requested; never use the real service.
    if let path = ProcessInfo.processInfo.environment["SHIPIOS_COUNTER_EVIDENCE"] {
      try FileManager.default.copyItem(at: root, to: URL(fileURLWithPath: path))
    }
    await store.shutdown()
  }
}
