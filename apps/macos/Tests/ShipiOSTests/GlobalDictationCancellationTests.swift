import AppKit
import Carbon.HIToolbox
import Observation
import XCTest
@testable import ShipiOS

@MainActor final class GlobalDictationCancellationTests: XCTestCase {
  func testEscapeCancelsPendingGlobalStartAndRemovesBothMonitors() throws {
    let fixture = Fixture()
    XCTAssertTrue(fixture.events.localCallbacks.isEmpty)
    try fixture.monitor.prepare(token: "global-dictation:pending")
    XCTAssertEqual(fixture.events.masks, [.keyDown, .keyDown])
    XCTAssertNil(fixture.events.localCallbacks[0](try key()))
    XCTAssertEqual(fixture.cancelled, ["global-dictation:pending"])
    XCTAssertNil(fixture.monitor.token)
    XCTAssertEqual(fixture.events.removed.count, 2)
    XCTAssertNotNil(fixture.events.localCallbacks[0](try key()))
    XCTAssertEqual(fixture.cancelled.count, 1)
  }

  func testGlobalCallbackWithHeldShortcutModifiersCancelsWithoutActivatingAWindow() async throws {
    let fixture = Fixture()
    try fixture.monitor.prepare(token: "global-dictation:hold")
    fixture.monitor.willStart(token: "global-dictation:hold")
    fixture.target.value = "global-dictation:hold"
    fixture.events.globalCallbacks[0](try key(flags: [.control, .option]))
    try await settle()
    XCTAssertEqual(fixture.cancelled, ["global-dictation:hold"])
    XCTAssertEqual(fixture.events.removed.count, 2)
  }

  func testOldQueuedEscapeOldEndAndOldStartResolutionCannotCancelNewSession() async throws {
    let fixture = Fixture()
    try fixture.monitor.prepare(token: "global-dictation:old")
    let queued = Task { @MainActor in fixture.events.globalCallbacks[0](try self.key()) }
    try fixture.monitor.prepare(token: "global-dictation:new")
    fixture.monitor.end(token: "global-dictation:old")
    fixture.monitor.didResolveStart(token: "global-dictation:old")
    try await queued.value
    try await settle()
    XCTAssertTrue(fixture.cancelled.isEmpty)
    XCTAssertEqual(fixture.monitor.token, "global-dictation:new")
    XCTAssertNotNil(fixture.events.localCallbacks[0](try key()))
    XCTAssertNil(fixture.events.localCallbacks[1](try key()))
    XCTAssertEqual(fixture.cancelled, ["global-dictation:new"])
  }

  func testRepeatedEscapeOtherKeysAndShortcutCapturePassThrough() throws {
    let fixture = Fixture()
    try fixture.monitor.prepare(token: "global-dictation:one")
    XCTAssertNotNil(fixture.events.localCallbacks[0](try key(repeated: true)))
    XCTAssertNotNil(fixture.events.localCallbacks[0](try key(code: 0)))
    fixture.capturing = true
    XCTAssertNotNil(fixture.events.localCallbacks[0](try key()))
    XCTAssertTrue(fixture.cancelled.isEmpty)
    fixture.capturing = false
    XCTAssertNil(fixture.events.localCallbacks[0](try key()))
    try fixture.monitor.prepare(token: "global-dictation:two")
    XCTAssertNotNil(fixture.events.localCallbacks[1](try key(repeated: true)))
    XCTAssertEqual(fixture.monitor.token, "global-dictation:two")
  }

  func testAutomaticCompletionTargetChangeAndStartFailureRemoveOnlyCurrentListeners() async throws {
    let fixture = Fixture()
    for ending in [String?.none, "composer:local"] {
      let token = "global-dictation:" + UUID().uuidString
      try fixture.monitor.prepare(token: token)
      fixture.monitor.willStart(token: token)
      fixture.target.value = token
      try await settle()
      XCTAssertEqual(fixture.monitor.token, token)
      fixture.target.value = ending
      try await settle()
      XCTAssertNil(fixture.monitor.token)
      XCTAssertTrue(fixture.cancelled.isEmpty)
    }
    try fixture.monitor.prepare(token: "global-dictation:failed")
    fixture.monitor.willStart(token: "global-dictation:failed")
    fixture.monitor.didResolveStart(token: "global-dictation:failed")
    XCTAssertNil(fixture.monitor.token)
    XCTAssertEqual(fixture.events.removed.count, 6)
  }

  func testTargetReplacementBeforeObservationCannotConsumeEscapeFromLocalComposer() throws {
    let fixture = Fixture()
    try fixture.monitor.prepare(token: "global-dictation:one")
    fixture.monitor.willStart(token: "global-dictation:one")
    fixture.target.value = "global-dictation:one"
    fixture.target.value = "composer:local"
    // The observation task has not run yet. Native delivery must check ownership.
    XCTAssertNotNil(fixture.events.localCallbacks[0](try key()))
    XCTAssertTrue(fixture.cancelled.isEmpty)
    XCTAssertNil(fixture.monitor.token)
  }

  func testPendingStartSurvivesUnrelatedObservationAndCancelDoesNotStopLocalDictation() async throws {
    let fixture = Fixture()
    try fixture.monitor.prepare(token: "global-dictation:pending")
    fixture.target.value = "composer:local"
    try await settle()
    XCTAssertEqual(fixture.monitor.token, "global-dictation:pending")
    let speech = SpeechDictation()
    var inserted: [String] = []
    let generation = speech.beginSession(target: "composer:local") { _, text in inserted.append(text) }
    XCTAssertTrue(speech.didStartCapture(token: generation))
    speech.receive(text: "本地草稿", isFinal: false, error: nil, token: generation)
    speech.stop(target: "global-dictation:pending", commitResult: false)
    XCTAssertEqual(speech.target, "composer:local")
    speech.receive(text: "本地草稿。", isFinal: true, error: nil, token: generation)
    XCTAssertEqual(inserted, ["本地草稿。"])
  }

  func testPartialMonitorRegistrationFailureTearsDownAndAllowsRetry() throws {
    for failedLocal in [true, false] {
      let fixture = Fixture()
      fixture.events.failLocal = failedLocal
      fixture.events.failGlobal = !failedLocal
      XCTAssertThrowsError(try fixture.monitor.prepare(token: "global-dictation:failed"))
      XCTAssertNil(fixture.monitor.token)
      XCTAssertEqual(fixture.events.removed.count, 1)
      fixture.events.failLocal = false; fixture.events.failGlobal = false
      try fixture.monitor.prepare(token: "global-dictation:retry")
      fixture.monitor.stop(); fixture.monitor.stop()
      XCTAssertEqual(fixture.events.removed.count, 3)
    }
  }

  func testMonitorDeallocationRemovesNativeTokensAndQueuedCallbackDoesNothing() async throws {
    let events = Events(), target = Target()
    var cancellations = 0
    var monitor: GlobalDictationCancellationMonitor? = .init(activeTarget: { target.value },
      isCapturingShortcut: { false }, events: events.adapter) { _ in cancellations += 1 }
    try monitor?.prepare(token: "global-dictation:one")
    let queued = Task { @MainActor in events.globalCallbacks[0](try self.key()) }
    monitor = nil
    try await queued.value
    try await settle()
    XCTAssertEqual(events.removed.count, 2)
    XCTAssertEqual(cancellations, 0)
  }

  func testCancelDiscardsListeningAndFinishingTextAndRejectsOldRecognitionCallbacks() throws {
    for finishing in [false, true] {
      let speech = SpeechDictation(), target = "global-dictation:one"
      var inserted: [String] = []
      let generation = speech.beginSession(target: target) { _, text in inserted.append(text) }
      XCTAssertTrue(speech.didStartCapture(token: generation))
      speech.receive(text: "绝不能插入", isFinal: false, error: nil, token: generation)
      XCTAssertEqual(speech.partial, "绝不能插入")
      if finishing { speech.finish(target: target); XCTAssertEqual(speech.phase, .finishing) }
      speech.stop(target: target, commitResult: false)
      XCTAssertEqual(speech.phase, .idle); XCTAssertNil(speech.target)
      speech.receive(text: "迟到的最终结果", isFinal: true, error: nil, token: generation)
      speech.receive(text: nil, isFinal: false, error: AgentFailure(message: "迟到错误"), token: generation)
      XCTAssertTrue(inserted.isEmpty); XCTAssertNil(speech.error)
      let next = speech.beginSession(target: "global-dictation:two") { _, text in inserted.append(text) }
      XCTAssertFalse(speech.didStartCapture(token: generation))
      XCTAssertTrue(speech.didStartCapture(token: next))
      speech.receive(text: "旧录音", isFinal: true, error: nil, token: generation)
      speech.stop(target: target, commitResult: false)
      XCTAssertEqual(speech.target, "global-dictation:two")
      speech.receive(text: "新录音", isFinal: true, error: nil, token: next)
      XCTAssertEqual(inserted, ["新录音"])
    }
  }

  func testCancelBeforeCaptureRejectsLateAuthorizationAndAllowsNextSession() {
    let speech = SpeechDictation()
    var inserted = false
    let old = speech.beginSession(target: "global-dictation:pending") { _, _ in inserted = true }
    XCTAssertEqual(speech.phase, .requestingAccess)
    speech.stop(target: "global-dictation:pending", commitResult: false)
    XCTAssertFalse(speech.didStartCapture(token: old))
    XCTAssertNil(speech.target); XCTAssertFalse(inserted)
  }

  func testCancelledFinishingTimeoutCannotCommitOrStopFollowingRecording() async throws {
    let speech = SpeechDictation()
    var inserted: [String] = []
    let old = speech.beginSession(target: "global-dictation:old") { _, text in inserted.append(text) }
    speech.didStartCapture(token: old)
    speech.receive(text: "被取消的部分结果", isFinal: false, error: nil, token: old)
    speech.finish(target: "global-dictation:old")
    XCTAssertEqual(speech.phase, .finishing)
    speech.stop(target: "global-dictation:old", commitResult: false)
    let next = speech.beginSession(target: "global-dictation:next") { _, text in inserted.append(text) }
    speech.didStartCapture(token: next)
    speech.receive(text: "下一次录音", isFinal: false, error: nil, token: next)
    try await Task.sleep(for: .milliseconds(5_150))
    XCTAssertEqual(speech.target, "global-dictation:next")
    XCTAssertEqual(speech.phase, .listening); XCTAssertTrue(inserted.isEmpty)
    speech.receive(text: "下一次录音。", isFinal: true, error: nil, token: next)
    XCTAssertEqual(inserted, ["下一次录音。"])
  }

  func testGlobalEscapeCancelsBeforeAnAlreadyQueuedFinalResultCanInsert() async throws {
    let speech = SpeechDictation(), events = Events()
    var inserted: [String] = []
    let token = "global-dictation:queued-final"
    let monitor = GlobalDictationCancellationMonitor(activeTarget: { speech.target },
      isCapturingShortcut: { false }, events: events.adapter) {
        speech.stop(target: $0, commitResult: false)
      }
    defer { monitor.stop() }
    try monitor.prepare(token: token); monitor.willStart(token: token)
    let generation = speech.beginSession(target: token) { _, text in inserted.append(text) }
    speech.didStartCapture(token: generation)
    let finalResult = Task { @MainActor in
      speech.receive(text: "不应插入的最终结果", isFinal: true, error: nil, token: generation)
    }
    // AppKit delivers the native callback on the main thread. Cancellation must
    // invalidate recognition before returning, even when a final task is queued.
    events.globalCallbacks[0](try key())
    XCTAssertNil(speech.target)
    await finalResult.value
    try await settle()
    XCTAssertTrue(inserted.isEmpty)
  }

  func testHoldCancellationIgnoresRepeatsUntilPhysicalReleaseAndStaleCancelKeepsNewHold() {
    var hold = GlobalDictationHoldState()
    XCTAssertEqual(hold.press(newToken: "one"), "one")
    hold.cancel(token: "one")
    XCTAssertNil(hold.token); XCTAssertNil(hold.press(newToken: "repeat"))
    XCTAssertNil(hold.release())
    XCTAssertEqual(hold.press(newToken: "two"), "two")
    hold.cancel(token: "one")
    XCTAssertEqual(hold.token, "two")
    XCTAssertEqual(hold.release(), "two")
    var toggle = GlobalDictationToggleState()
    XCTAssertEqual(toggle.press(activeTarget: nil, newToken: "old"), .start("old"))
    toggle.cancel(token: "old")
    toggle.didResolveStart(token: "old", active: true)
    XCTAssertNil(toggle.token)
    XCTAssertEqual(toggle.press(activeTarget: nil, newToken: "new"), .start("new"))
    toggle.cancel(token: "old"); XCTAssertEqual(toggle.token, "new")
  }

  func testBareModifierEscapeDoesNotFinishBeforeCancellationAndReleaseRearmsHold() {
    var modifiers = VoiceBareModifierState(), hold = GlobalDictationHoldState()
    let binding = ShortcutBinding("⌃⌥")
    XCTAssertEqual(modifiers.flagsChanged([.control, .option], hold: binding, toggle: nil), [.pressHold])
    XCTAssertEqual(hold.press(newToken: "one"), "one")
    XCTAssertEqual(modifiers.keyDown(currentFlags: [.control, .option], isEscape: true), [])
    hold.cancel(token: "one")
    XCTAssertNil(hold.press(newToken: "repeat"))
    XCTAssertEqual(modifiers.flagsChanged([], hold: binding, toggle: nil), [.releaseHold])
    XCTAssertNil(hold.release())
    XCTAssertEqual(modifiers.flagsChanged([.control, .option], hold: binding, toggle: nil), [.pressHold])
    XCTAssertEqual(hold.press(newToken: "two"), "two")
  }

  func testActualAppDelegateEscapeDiscardsSpeechAndPreservesShortcutCapturePriority() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root), delegate = AppDelegate(), events = Events()
    delegate.store = store
    let monitor = delegate.installGlobalDictationCancellation(events: events.adapter)
    defer { monitor.stop(); withExtendedLifetime(delegate) {} }
    var inserted: [String] = []
    let token = "global-dictation:actual-delegate"
    try monitor.prepare(token: token); monitor.willStart(token: token)
    let generation = store.dictation.beginSession(target: token) { _, text in inserted.append(text) }
    store.dictation.didStartCapture(token: generation)
    store.dictation.receive(text: "不要插入", isFinal: false, error: nil, token: generation)
    store.shortcutCaptureCount = 1
    XCTAssertNotNil(events.localCallbacks[0](try key()))
    XCTAssertEqual(store.dictation.target, token)
    store.shortcutCaptureCount = 0
    store.dictation.finish(target: token)
    XCTAssertNil(events.localCallbacks[0](try key()))
    XCTAssertNil(store.dictation.target); XCTAssertEqual(store.dictation.phase, .idle)
    XCTAssertEqual(store.dictation.completedTarget, token)
    store.dictation.receive(text: "迟到结果", isFinal: true, error: nil, token: generation)
    XCTAssertTrue(inserted.isEmpty)
    XCTAssertEqual(GlobalDictationIndicatorState.resolve(hasHotkey: true,
      target: store.dictation.target, phase: store.dictation.phase, hasError: false), .idle)
    XCTAssertEqual(events.removed.count, 2)
  }

  func testVoiceCarbonPressRepeatsCannotRestartCancelledRecordingUntilRelease() async throws {
    _ = NSApplication.shared
    var starts = 0
    let hotkey = AppGlobalHotKey(id: 68_901, title: "语音", allowsRepeat: false) { starts += 1 }
    try send(kEventHotKeyPressed, hotkey.eventIdentifier)
    try await settle(); XCTAssertEqual(starts, 1)
    // Escape cancels the recording while its starting shortcut is still held.
    try send(kEventHotKeyPressed, hotkey.eventIdentifier)
    try send(kEventHotKeyPressed, hotkey.eventIdentifier)
    try await settle(); XCTAssertEqual(starts, 1)
    try send(kEventHotKeyReleased, hotkey.eventIdentifier)
    try send(kEventHotKeyPressed, hotkey.eventIdentifier)
    try send(kEventHotKeyReleased, hotkey.eventIdentifier)
    try await settle(); XCTAssertEqual(starts, 2)
    withExtendedLifetime(hotkey) {}
  }

  private func send(_ kind: Int, _ identifier: EventHotKeyID) throws {
    var event: EventRef?
    XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kind), GetCurrentEventTime(), 0, &event), noErr)
    let value = try XCTUnwrap(event); defer { ReleaseEvent(value) }
    var identifier = identifier
    XCTAssertEqual(SetEventParameter(value, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
      MemoryLayout<EventHotKeyID>.size, &identifier), noErr)
    XCTAssertEqual(SendEventToEventTarget(value, GetApplicationEventTarget()), noErr)
  }

  private func key(code: UInt16 = 53, flags: NSEvent.ModifierFlags = [], repeated: Bool = false) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
      timestamp: 0, windowNumber: 0, context: nil, characters: code == 53 ? "\u{1b}" : "a",
      charactersIgnoringModifiers: code == 53 ? "\u{1b}" : "a", isARepeat: repeated, keyCode: code))
  }
  private func settle() async throws { try await Task.sleep(for: .milliseconds(30)) }

  @MainActor @Observable final class Target { var value: String? }
  @MainActor private final class Events {
    var localCallbacks: [(NSEvent) -> NSEvent?] = []
    var globalCallbacks: [(NSEvent) -> Void] = []
    var masks: [NSEvent.EventTypeMask] = []
    var removed: [UUID] = []
    var failLocal = false, failGlobal = false
    var adapter: GlobalDictationCancellationMonitor.EventMonitoring {
      .init(local: { [self] mask, callback in
        masks.append(mask); localCallbacks.append(callback); return failLocal ? nil : UUID()
      }, global: { [self] mask, callback in
        masks.append(mask); globalCallbacks.append(callback); return failGlobal ? nil : UUID()
      }, remove: { [self] in removed.append($0 as! UUID) })
    }
  }
  @MainActor private final class Fixture {
    let events = Events(), target = Target()
    var cancelled: [String] = []
    var capturing = false
    lazy var monitor = GlobalDictationCancellationMonitor(activeTarget: { [weak self] in self?.target.value },
      isCapturingShortcut: { [weak self] in self?.capturing ?? false }, events: events.adapter) { [weak self] in self?.cancelled.append($0) }
  }
}
