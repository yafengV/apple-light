import Foundation
import XCTest
@testable import ShipiOS

final class LocalEnvironmentScriptTests: XCTestCase {
  private func fixture() throws -> (URL, URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("environment process \(UUID())")
    let source = root.appendingPathComponent("source tree"), worktree = root.appendingPathComponent("work tree")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let path = try XCTUnwrap(ProcessInfo.processInfo.environment["SHIPIOS_TEST_AGENT"])
    let helper = URL(fileURLWithPath: path)
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))
    return (source, worktree, helper)
  }

  private func waitFor(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while !predicate() {
      guard ContinuousClock.now < deadline else { throw AgentFailure(message: "Environment process did not reach expected state") }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private let blockedScript = #"""
    printf '%s' "$$" > leader.pid
    /bin/zsh -c 'trap "" TERM; printf "%s" "$$" > grandchild.pid; while true; do /bin/sleep 0.1; done' &
    wait
    printf 'late' > late-result
    """#

  private func pids(in worktree: URL) throws -> [Int32] {
    try ["leader.pid", "grandchild.pid"].map {
      try XCTUnwrap(Int32(String(contentsOf: worktree.appendingPathComponent($0))))
    }
  }

  private func physicalPath(_ url: URL) throws -> String {
    let path = try XCTUnwrap(realpath(url.path, nil))
    defer { free(path) }
    return String(cString: path)
  }

  func testSetupAndCleanupRetainDirectoryEnvironmentAndFailureOutput() async throws {
    let (source, worktree, helper) = try fixture()
    let script = #"""
      pwd > phase-cwd
      printf '%s\n%s\n' "$CODEX_SOURCE_TREE_PATH" "$CODEX_WORKTREE_PATH" > environment-paths
      """#
    try await LocalEnvironmentScriptService.run(script, phase: .setup, source: source,
      worktree: worktree, supervisorExecutable: helper)
    XCTAssertEqual(try String(contentsOf: worktree.appendingPathComponent("phase-cwd")).trimmingCharacters(in: .whitespacesAndNewlines), try physicalPath(worktree))
    XCTAssertEqual(try String(contentsOf: worktree.appendingPathComponent("environment-paths")), "\(source.path)\n\(worktree.path)\n")
    try await LocalEnvironmentScriptService.run(script, phase: .cleanup, source: source,
      worktree: worktree, supervisorExecutable: helper)
    XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("phase-cwd")).trimmingCharacters(in: .whitespacesAndNewlines), try physicalPath(source))
    do {
      try await LocalEnvironmentScriptService.run("printf setup-stdout; printf setup-stderr >&2; exit 7",
        phase: .setup, source: source, worktree: worktree, supervisorExecutable: helper)
      XCTFail("A failing setup must not succeed")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("7"))
      XCTAssertTrue(error.localizedDescription.contains("setup-stdout"))
      XCTAssertTrue(error.localizedDescription.contains("setup-stderr"))
    }
  }

  func testCancellationStopsScriptAndTermResistantGrandchild() async throws {
    let (source, worktree, helper) = try fixture()
    let script = blockedScript
    let operation = Task {
      try await LocalEnvironmentScriptService.run(script, phase: .setup, source: source,
        worktree: worktree, supervisorExecutable: helper)
    }
    defer { operation.cancel() }
    try await waitFor { FileManager.default.fileExists(atPath: worktree.appendingPathComponent("grandchild.pid").path) }
    let owned = try pids(in: worktree)
    operation.cancel()
    do { try await operation.value; XCTFail("Cancellation must not succeed") }
    catch { XCTAssertTrue(error is CancellationError) }
    try await waitFor { owned.allSatisfy { kill($0, 0) != 0 && errno == ESRCH } }
    XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("late-result").path))
  }

  func testTimeoutStopsEntireScriptGroup() async throws {
    let (source, worktree, helper) = try fixture()
    do {
      try await LocalEnvironmentScriptService.run(blockedScript, phase: .setup, source: source,
        worktree: worktree, supervisorExecutable: helper, timeoutSeconds: 1)
      XCTFail("Timed out setup must not succeed")
    } catch { XCTAssertTrue(error.localizedDescription.contains("超过")) }
    let owned = try pids(in: worktree)
    try await waitFor { owned.allSatisfy { kill($0, 0) != 0 && errno == ESRCH } }
    XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("late-result").path))
  }

  func testOwnerPipeEOFStopsScriptAndGrandchildWithoutTerminationSignal() async throws {
    let (source, worktree, helper) = try fixture()
    let request = source.appendingPathComponent("request.json")
    try JSONSerialization.data(withJSONObject: ["script": blockedScript, "source": source.path,
      "worktree": worktree.path, "phase": "setup", "timeoutSeconds": 600]).write(to: request)
    let output = source.appendingPathComponent("result.json")
    XCTAssertTrue(FileManager.default.createFile(atPath: output.path, contents: nil))
    let handle = try FileHandle(forWritingTo: output), lifetime = Pipe(), process = Process()
    defer {
      try? lifetime.fileHandleForWriting.close()
      if process.isRunning { process.terminate() }
      try? handle.close()
    }
    process.executableURL = helper
    process.arguments = ["run-local-environment", "--request-file", request.path]
    process.standardInput = lifetime; process.standardOutput = handle; process.standardError = handle
    try process.run()
    try lifetime.fileHandleForReading.close()
    try await waitFor { FileManager.default.fileExists(atPath: worktree.appendingPathComponent("grandchild.pid").path) }
    let owned = try pids(in: worktree)
    try lifetime.fileHandleForWriting.close()
    try await waitFor { !process.isRunning }
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
    XCTAssertEqual(result["cancelled"] as? Bool, true)
    try await waitFor { owned.allSatisfy { kill($0, 0) != 0 && errno == ESRCH } }
    XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("late-result").path))
  }
}
