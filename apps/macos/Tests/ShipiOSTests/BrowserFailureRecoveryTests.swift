import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class BrowserFailureRecoveryTests: XCTestCase {
  func testRealNetworkFailureRetriesOriginalAddressWithoutChangingOtherPageOrDraft() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-recovery-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = root.appendingPathComponent("service-ready")
    let server = Process(), output = Pipe()
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/browser_server.py")
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = ["-u", script.path, "--recovery-gate", gate.path]
    server.standardOutput = output; server.standardError = FileHandle.nullDevice
    try server.run()
    defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
    let port = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertNotNil(Int(port))
    let base = "http://127.0.0.1:\(port)"
    let session = BrowserSession()
    defer { session.shutdown() }
    let target = session.newTab()
    target.address = base + "/one"; target.navigate()
    try await eventually { target.pageTitle == "One" && !target.loading && target.error == nil }
    let other = session.newTab()
    other.address = base + "/two"; other.navigate()
    try await eventually { other.pageTitle == "Two" && !other.loading && other.error == nil }
    other.setAddressDraft("Unsubmitted other address")
    session.select(target.id)
    let selection = session.selection
    let retryURL = base + "/recoverable"
    target.address = retryURL; target.navigate()
    try await eventually { target.error != nil && !target.loading }
    XCTAssertEqual(target.address, retryURL, "The retry action must retain the failed destination")
    XCTAssertEqual(session.selection, selection)
    XCTAssertEqual(other.committedURL?.absoluteString, base + "/two")
    XCTAssertEqual(other.address, "Unsubmitted other address")
    XCTAssertTrue(other.hasAddressInputDraft)
    // Restore the service, then invoke the same operation as BrowserPanel's Retry button.
    try Data().write(to: gate)
    target.navigate()
    try await eventually { target.pageTitle == "Recovered" && !target.loading && target.error == nil }
    XCTAssertEqual(target.committedURL?.absoluteString, retryURL)
    XCTAssertEqual(target.address, retryURL)
    XCTAssertEqual(session.selection, selection)
    XCTAssertEqual(other.pageTitle, "Two")
    XCTAssertEqual(other.address, "Unsubmitted other address")
    XCTAssertNil(other.error)
    // A network error arriving while the user edits must not replace their new draft.
    try FileManager.default.removeItem(at: gate)
    target.address = retryURL; target.navigate()
    let newerAddress = base + "/one?typed=1"
    target.setAddressDraft(newerAddress)
    try await eventually { target.error != nil && !target.loading }
    XCTAssertEqual(target.address, newerAddress)
    XCTAssertTrue(target.hasAddressInputDraft)
    XCTAssertEqual(other.address, "Unsubmitted other address")
    try Data().write(to: gate)
    target.navigate()
    try await eventually { target.pageTitle == "One" && !target.loading && target.error == nil }
    XCTAssertEqual(target.committedURL?.absoluteString, newerAddress)
    XCTAssertFalse(target.hasAddressInputDraft)
    target.close()
    target.navigate()
    XCTAssertTrue(target.closed)
    XCTAssertFalse(target.loading)
    XCTAssertNil(target.error)
  }

  private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<320 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    throw AgentFailure(message: "Local WebKit recovery did not reach its expected state")
  }
}
