import XCTest
@testable import ShipiOS

final class ModelFaultRecoveryTests: XCTestCase {
  @MainActor func testSilentHTTPProviderFailsWithinLimitRetainsDraftAndPartialAndRetries() async throws {
    try await checkFault(apiProtocol: .chatCompletions, mode: "idle")
  }

  @MainActor func testCurrentCoreDeltasRetainPartialWithoutReplayDuplicationAndRetry() async throws {
    try await checkFault(apiProtocol: .codexResponses, mode: "truncated")
  }

  @MainActor private func checkFault(apiProtocol: ModelAPIProtocol, mode: String) async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let server = Process(), output = Pipe()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = [repository.appendingPathComponent("script/smoke_model_failures.py").path, "--serve"]
    server.standardOutput = output
    try server.run()
    defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
    let data = output.fileHandleForReading.availableData
    let port = try XCTUnwrap(Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-idle-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root,
      agentExecutable: apiProtocol == .codexResponses ? try AgentTestExecutable.url() : nil)
    await store.restore()
    var config = ModelConfiguration()
    config.baseURL = "http://127.0.0.1:\(port)/\(mode)/v1"; config.model = "gpt-5.4"
    config.apiProtocol = apiProtocol
    try store.saveModelConfiguration(config)
    store.notificationPreferences = .init(timing: .never)
    let began = ContinuousClock.now
    let started = await store.startChat("silent provider")
    let run = try XCTUnwrap(started)
    store.draft = "UNSENT_DRAFT"
    for _ in 0..<580 {
      if !store.library.chatRuns.contains(where: { $0.id == run && $0.isActive }) { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    let failed = try XCTUnwrap(store.library.chatRuns.first { $0.id == run })
    XCTAssertEqual(failed.status, "failed")
    XCTAssertEqual(failed.result?["response"].text, "PARTIAL_RETAINED")
    XCTAssertFalse((failed.result?["message"].text ?? "").isEmpty)
    XCTAssertLessThan(began.duration(to: .now), .seconds(60))
    XCTAssertEqual(store.draft, "UNSENT_DRAFT")
    // Even a regression must release the request and fixture process.
    if failed.isActive { await store.cancel() }
    await store.modelTask(runID: run)?.value
    XCTAssertEqual(store.liveModelRequestCount, 0)
    let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/recover/\(mode)")!)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    await store.rerun()
    await store.modelTask?.value
    XCTAssertEqual(store.selectedRun?.status, "succeeded")
    XCTAssertEqual(store.selectedRun?.result?["response"].text, "RECOVERED_REPLY")
    XCTAssertEqual(store.draft, "UNSENT_DRAFT")
    await store.shutdown()
  }
}
