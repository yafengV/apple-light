import IOKit.pwr_mgt
import XCTest

@testable import ShipiOS

private final class FakeIdleSleepAssertion: IdleSleepAssertion {
  var releaseAttempts = 0
  var failRelease = false
  func release() throws {
    releaseAttempts += 1
    if failRelease { throw AgentFailure(message: "release failed") }
  }
}

final class SleepPreventionTests: XCTestCase {
  private func sampleRun(kind: String = "build", status: String = "running") -> AgentRun {
    AgentRun(id: UUID().uuidString, kind: kind, project: "/fixture", status: status,
      createdAt: 0, updatedAt: 0, request: .null, result: nil)
  }

  @MainActor func testOnlyRunningEnabledWorkAcquiresAndRepeatedUpdatesDoNotLeak() {
    var tokens: [FakeIdleSleepAssertion] = []
    let prevention = SleepPrevention {
      let token = FakeIdleSleepAssertion(); tokens.append(token); return token
    }
    prevention.update(enabled: false, hasRunningWork: true)
    prevention.update(enabled: true, hasRunningWork: false)
    XCTAssertTrue(tokens.isEmpty)
    for _ in 0..<30 { prevention.update(enabled: true, hasRunningWork: true) }
    XCTAssertTrue(prevention.active)
    XCTAssertEqual(tokens.count, 1)
    prevention.update(enabled: false, hasRunningWork: true)
    XCTAssertFalse(prevention.active)
    XCTAssertEqual(tokens[0].releaseAttempts, 1)
    prevention.update(enabled: true, hasRunningWork: true)
    XCTAssertEqual(tokens.count, 2)
    prevention.stop()
    prevention.stop()
    XCTAssertEqual(tokens[1].releaseAttempts, 1)
  }

  @MainActor func testFailuresAreVisibleAndRetryDoesNotDropHeldAssertion() {
    let token = FakeIdleSleepAssertion()
    var attempts = 0
    let prevention = SleepPrevention {
      attempts += 1
      if attempts == 1 { throw AgentFailure(message: "create failed") }
      return token
    }
    prevention.update(enabled: true, hasRunningWork: true)
    XCTAssertFalse(prevention.active)
    XCTAssertEqual(prevention.error, "create failed")
    prevention.update(enabled: true, hasRunningWork: true)
    XCTAssertEqual(attempts, 1)
    prevention.update(enabled: true, hasRunningWork: true, force: true)
    XCTAssertTrue(prevention.active)
    XCTAssertNil(prevention.error)
    token.failRelease = true
    prevention.update(enabled: true, hasRunningWork: false)
    XCTAssertTrue(prevention.active)
    XCTAssertEqual(prevention.error, "release failed")
    token.failRelease = false
    prevention.stop()
    XCTAssertFalse(prevention.active)
    XCTAssertNil(prevention.error)
    XCTAssertEqual(token.releaseAttempts, 2)
  }

  @MainActor func testEveryTerminalStateReleasesAndSettingsNavigationKeepsActiveWork() {
    let store = WorkspaceStore()
    var tokens: [FakeIdleSleepAssertion] = []
    store.sleepPrevention = SleepPrevention {
      let token = FakeIdleSleepAssertion(); tokens.append(token); return token
    }
    store.library.preventIdleSleep = true
    store.connected = true
    for state in ["succeeded", "failed", "cancelled", "interrupted"] {
      store.runs = [sampleRun()]
      XCTAssertTrue(store.sleepPrevention.active)
      store.openSettings(.general)
      XCTAssertTrue(store.sleepPrevention.active)
      store.closeSettings()
      store.runs = [sampleRun(status: state)]
      XCTAssertFalse(store.sleepPrevention.active)
    }
    XCTAssertEqual(tokens.count, 4)
    XCTAssertTrue(tokens.allSatisfy { $0.releaseAttempts == 1 })
  }

  @MainActor func testAgentDisconnectDoesNotDropIndependentChatAssertion() {
    let store = WorkspaceStore()
    var tokens: [FakeIdleSleepAssertion] = []
    store.sleepPrevention = SleepPrevention {
      let token = FakeIdleSleepAssertion(); tokens.append(token); return token
    }
    store.library.preventIdleSleep = true
    store.connected = true
    store.runs = [sampleRun()]
    store.connected = false
    XCTAssertFalse(store.sleepPrevention.active)
    store.runs = [sampleRun(kind: "chat")]
    XCTAssertFalse(store.sleepPrevention.active, "A restored record without a live model task is not running work")
    store.modelTask = Task {}
    XCTAssertTrue(store.sleepPrevention.active)
    store.connected = true
    store.connected = false
    XCTAssertTrue(store.sleepPrevention.active)
    store.modelTask = nil
    XCTAssertFalse(store.sleepPrevention.active)
    XCTAssertEqual(tokens.count, 2)
    XCTAssertTrue(tokens.allSatisfy { $0.releaseAttempts == 1 })
  }

  @MainActor func testShutdownReleasesAndLateUpdatesCannotReacquire() async {
    let store = WorkspaceStore()
    var created = 0
    let token = FakeIdleSleepAssertion()
    store.sleepPrevention = SleepPrevention { created += 1; return token }
    store.library.preventIdleSleep = true
    store.connected = true
    store.runs = [sampleRun()]
    XCTAssertTrue(store.sleepPrevention.active)
    await store.shutdown()
    XCTAssertFalse(store.sleepPrevention.active)
    store.connected = true
    store.runs = [sampleRun()]
    XCTAssertFalse(store.sleepPrevention.active)
    XCTAssertEqual(created, 1)
    XCTAssertEqual(token.releaseAttempts, 1)
  }

  @MainActor func testPreferenceRestoresWithoutActivatingForOldHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    store.preventIdleSleep = true
    XCTAssertFalse(store.sleepPrevention.active)
    let saved = try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json"))
    XCTAssertTrue(saved.preventIdleSleep)
    let restored = WorkspaceStore(dataRoot: root)
    await restored.restore()
    restored.runs = [sampleRun(status: "succeeded")]
    XCTAssertTrue(restored.preventIdleSleep)
    XCTAssertFalse(restored.sleepPrevention.active)
    let legacy = try JSONDecoder().decode(WorkspaceLibrary.self, from: Data("{}".utf8))
    XCTAssertFalse(legacy.preventIdleSleep)
  }

  @MainActor func testTogglingDuringWorkTakesEffectAndFailedSaveKeepsActualPreference() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    await store.restore()
    let token = FakeIdleSleepAssertion()
    store.sleepPrevention = SleepPrevention { token }
    store.connected = true
    store.runs = [sampleRun()]
    XCTAssertFalse(store.sleepPrevention.active)
    store.preventIdleSleep = true
    XCTAssertTrue(store.sleepPrevention.active)
    store.preventIdleSleep = false
    XCTAssertFalse(store.sleepPrevention.active)
    XCTAssertEqual(token.releaseAttempts, 1)
    let url = root.appendingPathComponent("workspace.json")
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    store.preventIdleSleep = true
    XCTAssertFalse(store.preventIdleSleep)
    XCTAssertFalse(store.sleepPrevention.active)
    XCTAssertNotNil(store.sleepPrevention.error)
  }

  func testRealAssertionPropertiesAndExplicitRelease() throws {
    let name = "ShipiOS test \(UUID())"
    let assertion = try SystemIdleSleepAssertion(name: name)
    defer { try? assertion.release() }
    let id = try XCTUnwrap(assertion.id)
    let properties = try XCTUnwrap(IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [String: Any])
    XCTAssertEqual(properties[kIOPMAssertionNameKey as String] as? String, name)
    XCTAssertEqual(properties[kIOPMAssertionTypeKey as String] as? String, kIOPMAssertPreventUserIdleSystemSleep as String)
    XCTAssertEqual(properties[kIOPMAssertionLevelKey as String] as? Int, Int(kIOPMAssertionLevelOn))
    try assertion.release()
    XCTAssertNil(assertion.id)
    XCTAssertNil(IOPMAssertionCopyProperties(id))
  }

  func testRealAssertionIsReleasedWhenOwnerIsDestroyed() throws {
    var assertion: SystemIdleSleepAssertion? = try SystemIdleSleepAssertion(name: "ShipiOS lifetime test")
    let id = try XCTUnwrap(assertion?.id)
    assertion = nil
    XCTAssertNil(IOPMAssertionCopyProperties(id))
  }
}
