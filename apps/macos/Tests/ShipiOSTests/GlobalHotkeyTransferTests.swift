import AppKit
import Carbon.HIToolbox
import XCTest
@testable import ShipiOS

@MainActor final class GlobalHotkeyTransferTests: XCTestCase {
  func testVoiceBindingsCanSwapWithoutTemporarilyUnregisteringOldCombinations() throws {
    let fixture = try Fixture()
    let transaction = VoiceHotkeyRegistrationTransaction(hold: fixture.first, toggle: fixture.second, voiceChat: fixture.third)
    let previous = VoicePreferences(globalHoldHotkey: fixture.bindings[0], globalToggleHotkey: fixture.bindings[1])
    try fixture.first.register(fixture.bindings[0]); try fixture.second.register(fixture.bindings[1])
    var next = previous
    next.globalHoldHotkey = fixture.bindings[1]; next.globalToggleHotkey = fixture.bindings[0]
    var saves = 0
    try transaction.commit(next, replacing: previous) {
      saves += 1
      for binding in fixture.bindings.prefix(2) { XCTAssertThrowsError(try fixture.probe.register(binding)) }
    }
    XCTAssertEqual(saves, 1)
    try fixture.first.register(nil)
    try fixture.probe.register(fixture.bindings[1]); try fixture.probe.register(nil)
    XCTAssertThrowsError(try fixture.probe.register(fixture.bindings[0]))
  }

  func testCommandBindingsCanSwapAndOnlyReleaseTheirNewCombinationOnClear() throws {
    let fixture = try Fixture()
    let registration = CommandGlobalHotkeyRegistration(pet: fixture.first, popout: fixture.second)
    let previous = CommandGlobalHotkeyBindings(pet: fixture.bindings[0], popout: fixture.bindings[1])
    try fixture.first.register(fixture.bindings[0]); try fixture.second.register(fixture.bindings[1])
    let next = CommandGlobalHotkeyBindings(pet: fixture.bindings[1], popout: fixture.bindings[0])
    var saves = 0
    try registration.commit(next, replacing: previous) {
      saves += 1
      for binding in fixture.bindings.prefix(2) { XCTAssertThrowsError(try fixture.probe.register(binding)) }
    }
    XCTAssertEqual(saves, 1)
    try fixture.second.register(nil)
    try fixture.probe.register(fixture.bindings[0]); try fixture.probe.register(nil)
    XCTAssertThrowsError(try fixture.probe.register(fixture.bindings[1]))
  }

  func testFailedVoiceAndCommandSwapDoesNotReleaseOrReassignAnything() throws {
    for voice in [true, false] {
      let fixture = try Fixture()
      try fixture.first.register(fixture.bindings[0]); try fixture.second.register(fixture.bindings[1])
      let ids = [fixture.first.eventIdentifier.id, fixture.second.eventIdentifier.id]
      var saves = 0
      let fail = { saves += 1; throw AgentFailure(message: "test save failure") }
      if voice {
        let transaction = VoiceHotkeyRegistrationTransaction(hold: fixture.first, toggle: fixture.second, voiceChat: fixture.third)
        XCTAssertThrowsError(try transaction.commit(
          VoicePreferences(globalHoldHotkey: fixture.bindings[1], globalToggleHotkey: fixture.bindings[0]),
          replacing: VoicePreferences(globalHoldHotkey: fixture.bindings[0], globalToggleHotkey: fixture.bindings[1]),
          persist: fail))
      } else {
        let registration = CommandGlobalHotkeyRegistration(pet: fixture.first, popout: fixture.second)
        XCTAssertThrowsError(try registration.commit(
          CommandGlobalHotkeyBindings(pet: fixture.bindings[1], popout: fixture.bindings[0]),
          replacing: CommandGlobalHotkeyBindings(pet: fixture.bindings[0], popout: fixture.bindings[1]), persist: fail))
      }
      XCTAssertEqual(saves, 1)
      XCTAssertEqual([fixture.first.eventIdentifier.id, fixture.second.eventIdentifier.id], ids)
      for binding in fixture.bindings.prefix(2) { XCTAssertThrowsError(try fixture.probe.register(binding)) }
      try fixture.first.register(nil)
      try fixture.probe.register(fixture.bindings[0]); try fixture.probe.register(nil)
      XCTAssertThrowsError(try fixture.probe.register(fixture.bindings[1]))
    }
  }

  func testThreeWayCycleReusesEachRegistrationAndCommitDoesNotRetainClearedKeys() throws {
    let fixture = try Fixture(), keys = [fixture.first, fixture.second, fixture.third]
    for (key, binding) in zip(keys, fixture.bindings) { try key.register(binding) }
    let ids = keys.map { $0.eventIdentifier.id }
    let prepared = try AppGlobalHotKey.prepareRegistrations([
      (fixture.first, fixture.bindings[1]), (fixture.second, fixture.bindings[2]), (fixture.third, fixture.bindings[0])])
    prepared.commit(); prepared.commit()
    XCTAssertEqual(keys.map { $0.eventIdentifier.id }, [ids[1], ids[2], ids[0]])
    for binding in fixture.bindings.prefix(3) { XCTAssertThrowsError(try fixture.probe.register(binding)) }
    for key in keys { try key.register(nil) }
    for binding in fixture.bindings.prefix(3) { try fixture.probe.register(binding); try fixture.probe.register(nil) }
    withExtendedLifetime(prepared) {}
  }

  func testDiscardedTransferAndFreshCandidateKeepOldOwnersAndReleaseOnlyCandidate() throws {
    let fixture = try Fixture()
    try fixture.first.register(fixture.bindings[0]); try fixture.second.register(fixture.bindings[1])
    let ids = [fixture.first.eventIdentifier.id, fixture.second.eventIdentifier.id]
    do {
      let prepared = try AppGlobalHotKey.prepareRegistrations([
        (fixture.first, fixture.bindings[2]), (fixture.second, fixture.bindings[0])])
      for binding in fixture.bindings.prefix(3) { XCTAssertThrowsError(try fixture.probe.register(binding)) }
      XCTAssertEqual([fixture.first.eventIdentifier.id, fixture.second.eventIdentifier.id], ids)
      withExtendedLifetime(prepared) {}
    }
    for binding in fixture.bindings.prefix(2) { XCTAssertThrowsError(try fixture.probe.register(binding)) }
    try fixture.probe.register(fixture.bindings[2]); try fixture.probe.register(nil)
    XCTAssertEqual([fixture.first.eventIdentifier.id, fixture.second.eventIdentifier.id], ids)
  }

  func testLaterInvalidCandidateDiscardsFreshEarlierCandidateAndKeepsTransferredSource() throws {
    let fixture = try Fixture()
    try fixture.first.register(fixture.bindings[0]); try fixture.second.register(fixture.bindings[1])
    XCTAssertThrowsError(try AppGlobalHotKey.prepareRegistrations([
      (fixture.first, fixture.bindings[2]), (fixture.second, fixture.bindings[0]),
      (fixture.third, ShortcutBinding("⌃⌥😀"))])) {
      XCTAssertEqual(($0 as? AppGlobalHotKey.PreparationFailure)?.index, 2)
    }
    for binding in fixture.bindings.prefix(2) { XCTAssertThrowsError(try fixture.probe.register(binding)) }
    try fixture.probe.register(fixture.bindings[2]); try fixture.probe.register(nil)
    try fixture.first.register(nil)
    try fixture.probe.register(fixture.bindings[0]); try fixture.probe.register(nil)
    XCTAssertThrowsError(try fixture.probe.register(fixture.bindings[1]))
  }

  func testUnchangedAndForeignOwnersCannotDonateAndDuplicateRequestsAreRejected() throws {
    let fixture = try Fixture()
    try fixture.first.register(fixture.bindings[0]); try fixture.second.register(fixture.bindings[1])
    XCTAssertThrowsError(try AppGlobalHotKey.prepareRegistrations([(fixture.third, fixture.bindings[0])]))
    XCTAssertThrowsError(try AppGlobalHotKey.prepareRegistrations([
      (fixture.first, fixture.bindings[1]), (fixture.second, fixture.bindings[1])]))
    XCTAssertThrowsError(try AppGlobalHotKey.prepareRegistrations([
      (fixture.first, nil), (fixture.first, fixture.bindings[2])]))
    for binding in fixture.bindings.prefix(2) { XCTAssertThrowsError(try fixture.probe.register(binding)) }
    try fixture.probe.register(fixture.bindings[2]); try fixture.probe.register(nil)
  }

  func testTransferAndFreshCandidateHaveDistinctIDsAndDispatchOnlyToTheirOwners() async throws {
    let fixture = try Fixture(), counts = Counts()
    let first = AppGlobalHotKey(id: 68_710, title: "一") { counts.first += 1 }
    let second = AppGlobalHotKey(id: 68_711, title: "二") { counts.second += 1 }
    try first.register(fixture.bindings[0]); try second.register(fixture.bindings[1])
    let transferredID = first.eventIdentifier.id
    let prepared = try AppGlobalHotKey.prepareRegistrations([(first, fixture.bindings[2]), (second, fixture.bindings[0])])
    prepared.commit()
    XCTAssertNotEqual(first.eventIdentifier.id, transferredID)
    XCTAssertEqual(second.eventIdentifier.id, transferredID)
    try send(kEventHotKeyPressed, first.eventIdentifier); try send(kEventHotKeyReleased, first.eventIdentifier)
    try send(kEventHotKeyPressed, second.eventIdentifier); try send(kEventHotKeyReleased, second.eventIdentifier)
    try await settle()
    XCTAssertEqual(counts.first, 1); XCTAssertEqual(counts.second, 1)
  }

  func testTransferredRegistrationSurvivesOriginalOwnersDeinit() async throws {
    let fixture = try Fixture(), counts = Counts()
    var donor: AppGlobalHotKey? = AppGlobalHotKey(id: 68_712, title: "旧动作") { counts.first += 1 }
    weak var old = donor
    let recipient = AppGlobalHotKey(id: 68_713, title: "新动作") { counts.second += 1 }
    try donor?.register(fixture.bindings[0])
    let prepared = try AppGlobalHotKey.prepareRegistrations([(try XCTUnwrap(donor), nil), (recipient, fixture.bindings[0])])
    prepared.commit(); donor = nil
    XCTAssertNil(old)
    XCTAssertThrowsError(try fixture.probe.register(fixture.bindings[0]))
    try send(kEventHotKeyPressed, recipient.eventIdentifier); try send(kEventHotKeyReleased, recipient.eventIdentifier)
    try await settle(); XCTAssertEqual(counts.first, 0); XCTAssertEqual(counts.second, 1)
    try recipient.register(nil)
    try fixture.probe.register(fixture.bindings[0]); try fixture.probe.register(nil)
    withExtendedLifetime(prepared) {}
  }

  func testHeldTransferKeepsReleaseAtOriginalActionAndSuppressesRepeatUntilRelease() async throws {
    let fixture = try Fixture(), counts = Counts()
    let donor = AppGlobalHotKey(id: 68_714, title: "旧动作", onRelease: { counts.firstRelease += 1 }) { counts.first += 1 }
    let recipient = AppGlobalHotKey(id: 68_715, title: "新动作", onRelease: { counts.secondRelease += 1 }) { counts.second += 1 }
    try donor.register(fixture.bindings[0]); let id = donor.eventIdentifier
    try send(kEventHotKeyPressed, id); try await settle(); XCTAssertEqual(counts.first, 1)
    try AppGlobalHotKey.prepareRegistrations([(donor, nil), (recipient, fixture.bindings[0])]).commit()
    try send(kEventHotKeyPressed, id); try send(kEventHotKeyReleased, id); try await settle()
    XCTAssertEqual(counts.first, 1); XCTAssertEqual(counts.second, 0)
    XCTAssertEqual(counts.firstRelease, 1); XCTAssertEqual(counts.secondRelease, 0)
    try send(kEventHotKeyPressed, id); try send(kEventHotKeyReleased, id); try await settle()
    XCTAssertEqual(counts.second, 1); XCTAssertEqual(counts.secondRelease, 1)
  }

  func testQueuedPressBeforeTransferCannotInvokeEitherActionAfterCommit() async throws {
    let fixture = try Fixture(), counts = Counts()
    let donor = AppGlobalHotKey(id: 68_716, title: "旧动作", onRelease: { counts.firstRelease += 1 }) { counts.first += 1 }
    let recipient = AppGlobalHotKey(id: 68_717, title: "新动作") { counts.second += 1 }
    try donor.register(fixture.bindings[0]); let id = donor.eventIdentifier
    try send(kEventHotKeyPressed, id)
    try AppGlobalHotKey.prepareRegistrations([(donor, nil), (recipient, fixture.bindings[0])]).commit()
    try await settle(); XCTAssertEqual(counts.first, 0); XCTAssertEqual(counts.second, 0)
    try send(kEventHotKeyReleased, id); try await settle(); XCTAssertEqual(counts.firstRelease, 1)
    try send(kEventHotKeyPressed, id); try send(kEventHotKeyReleased, id); try await settle()
    XCTAssertEqual(counts.second, 1)
  }

  func testTransferredCaptureDropsOldQueuedInputAndConsumesItsReleaseBeforeNewCapture() async throws {
    let fixture = try Fixture(), counts = Counts()
    let donor = AppGlobalHotKey(id: 68_718, title: "旧动作", onRelease: { counts.firstRelease += 1 }) { counts.first += 1 }
    let recipient = AppGlobalHotKey(id: 68_719, title: "新动作", onRelease: { counts.secondRelease += 1 }) { counts.second += 1 }
    try donor.register(fixture.bindings[0]); let id = donor.eventIdentifier
    let window = Window(contentRect: .init(x: 0, y: 0, width: 280, height: 80),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let field = ShortcutCapture.Field(); field.frame = .init(x: 10, y: 10, width: 144, height: 28)
    let root = NSView(frame: window.contentLayoutRect); root.addSubview(field); window.contentView = root
    var captures: [ShortcutBinding] = []
    field.receiveRegistered = { captures.append($0) }; field.install(); defer { field.stop() }
    XCTAssertTrue(window.makeFirstResponder(field)); try send(kEventHotKeyPressed, id)
    try AppGlobalHotKey.prepareRegistrations([(donor, nil), (recipient, fixture.bindings[0])]).commit()
    try await settle(); XCTAssertTrue(captures.isEmpty)
    try send(kEventHotKeyReleased, id); try await settle()
    XCTAssertEqual(counts.firstRelease, 0); XCTAssertEqual(counts.secondRelease, 0)
    try send(kEventHotKeyPressed, id); try await settle()
    XCTAssertEqual(captures, [fixture.bindings[0]])
    try send(kEventHotKeyReleased, id); try await settle()
    XCTAssertEqual(counts.first, 0); XCTAssertEqual(counts.second, 0)
    XCTAssertFalse(window.isVisible)
  }

  func testSharedWorkspaceSaveTransfersBindingsBothDirectionsAcrossControllers() throws {
    let fixture = try StoreFixture(); defer { fixture.clean() }
    try fixture.store.shortcuts.set(fixture.native.bindings[0], for: "pet")
    var voice = fixture.store.voicePreferences; voice.globalHoldHotkey = fixture.native.bindings[0]
    var snapshot = fixture.store.shortcuts.snapshot; snapshot.overrides["pet"] = []
    let id = fixture.pet.eventIdentifier.id
    try fixture.store.saveVoicePreferences(voice, shortcutSnapshot: snapshot)
    XCTAssertEqual(fixture.store.shortcuts.binding("pet"), nil)
    XCTAssertEqual(fixture.native.first.eventIdentifier.id, id)
    XCTAssertEqual(fixture.store.voicePreferences.globalHoldHotkey, fixture.native.bindings[0])
    XCTAssertEqual(try fixture.saved().voicePreferences, voice)
    XCTAssertEqual(try fixture.saved().shortcutPreferences?.overrides["pet"], [])
    voice.globalHoldHotkey = nil; snapshot.overrides["popout"] = [fixture.native.bindings[0]]
    try fixture.store.saveVoicePreferences(voice, shortcutSnapshot: snapshot)
    XCTAssertEqual(fixture.popout.eventIdentifier.id, id)
    XCTAssertNil(fixture.store.voicePreferences.globalHoldHotkey)
    XCTAssertEqual(fixture.store.shortcuts.binding("popout"), fixture.native.bindings[0])
    XCTAssertThrowsError(try fixture.native.probe.register(fixture.native.bindings[0]))
    try fixture.store.shortcuts.set(nil, for: "popout")
    try fixture.native.probe.register(fixture.native.bindings[0]); try fixture.native.probe.register(nil)
  }

  func testSharedWorkspaceTransferDiskFailurePreservesFileSettingsAndNativeOwners() throws {
    let fixture = try StoreFixture(); defer { fixture.clean() }
    try fixture.store.shortcuts.set(fixture.native.bindings[0], for: "globalDictationHold")
    let file = fixture.root.appendingPathComponent("workspace.json"), before = try Data(contentsOf: file)
    var voice = fixture.store.voicePreferences; voice.globalHoldHotkey = nil
    var snapshot = fixture.store.shortcuts.snapshot; snapshot.overrides["popout"] = [fixture.native.bindings[0]]
    let oldID = fixture.native.first.eventIdentifier.id
    try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    XCTAssertThrowsError(try fixture.store.saveVoicePreferences(voice, shortcutSnapshot: snapshot))
    XCTAssertEqual(fixture.native.first.eventIdentifier.id, oldID)
    XCTAssertEqual(fixture.store.voicePreferences.globalHoldHotkey, fixture.native.bindings[0])
    XCTAssertNil(fixture.store.shortcuts.binding("popout"))
    XCTAssertThrowsError(try fixture.native.probe.register(fixture.native.bindings[0]))
    try FileManager.default.removeItem(at: file); try before.write(to: file)
    XCTAssertEqual(try fixture.saved().voicePreferences, fixture.store.voicePreferences)
    try fixture.store.saveVoicePreferences(voice, shortcutSnapshot: snapshot)
    XCTAssertEqual(fixture.popout.eventIdentifier.id, oldID)
    XCTAssertNil(fixture.store.voicePreferences.globalHoldHotkey)
  }

  func testSharedWorkspaceExternalConflictsAreReportedOnOnlyTheFailingCommand() throws {
    let fixture = try StoreFixture(); defer { fixture.clean() }
    try fixture.store.shortcuts.set(fixture.native.bindings[0], for: "globalDictationHold")
    let blocker = AppGlobalHotKey(id: 68_723, title: "外部占用") {}
    try blocker.register(fixture.native.bindings[2])
    var voice = fixture.store.voicePreferences; voice.globalHoldHotkey = nil
    var snapshot = fixture.store.shortcuts.snapshot
    snapshot.overrides["pet"] = [fixture.native.bindings[2]]
    snapshot.overrides["popout"] = [fixture.native.bindings[0]]
    XCTAssertThrowsError(try fixture.store.saveVoicePreferences(voice, shortcutSnapshot: snapshot))
    XCTAssertNotNil(fixture.store.shortcuts.globalRegistrationErrors["pet"])
    XCTAssertTrue(fixture.store.voiceShortcutRegistrationErrors.isEmpty)
    XCTAssertEqual(fixture.store.voicePreferences.globalHoldHotkey, fixture.native.bindings[0])
    snapshot.overrides["pet"] = []; snapshot.overrides["popout"] = []
    voice.globalHoldHotkey = fixture.native.bindings[2]
    fixture.store.shortcuts.globalRegistrationErrors.removeAll()
    XCTAssertThrowsError(try fixture.store.saveVoicePreferences(voice, shortcutSnapshot: snapshot))
    XCTAssertNotNil(fixture.store.voiceShortcutRegistrationErrors[.hold])
    XCTAssertTrue(fixture.store.shortcuts.globalRegistrationErrors.isEmpty)
    XCTAssertThrowsError(try fixture.native.probe.register(fixture.native.bindings[0]))
  }

  func testActualResetAllTransfersVoiceBindingToRestoredPetDefault() throws {
    let fixture = try StoreFixture(controlledPetDefault: true); defer { fixture.clean() }
    let binding = fixture.native.bindings[0]
    try fixture.store.shortcuts.set(binding, for: "globalDictationHold")
    let sourceID = fixture.native.first.eventIdentifier.id
    try fixture.store.shortcuts.resetAll()
    XCTAssertNil(fixture.store.voicePreferences.globalHoldHotkey)
    XCTAssertEqual(fixture.store.shortcuts.binding("pet"), binding)
    XCTAssertEqual(fixture.pet.eventIdentifier.id, sourceID)
    XCTAssertTrue(fixture.store.shortcuts.overrides.isEmpty)
    XCTAssertFalse(fixture.store.shortcuts.hasCustomizations)
    XCTAssertNil(try fixture.saved().voicePreferences.globalHoldHotkey)
    XCTAssertTrue(try fixture.saved().shortcutPreferences?.overrides.isEmpty == true)
    XCTAssertThrowsError(try fixture.native.probe.register(binding))
    try fixture.store.shortcuts.set(nil, for: "pet")
    try fixture.native.probe.register(binding); try fixture.native.probe.register(nil)
  }

  func testActualResetAllTransferSaveFailureRetainsVoiceOwnerAndRetryRestoresPet() throws {
    let fixture = try StoreFixture(controlledPetDefault: true); defer { fixture.clean() }
    let binding = fixture.native.bindings[0]
    try fixture.store.shortcuts.set(binding, for: "globalDictationHold")
    let id = fixture.native.first.eventIdentifier.id
    let file = fixture.root.appendingPathComponent("workspace.json"), before = try Data(contentsOf: file)
    try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    XCTAssertThrowsError(try fixture.store.shortcuts.resetAll())
    XCTAssertEqual(fixture.store.voicePreferences.globalHoldHotkey, binding)
    XCTAssertNil(fixture.store.shortcuts.binding("pet"))
    XCTAssertEqual(fixture.native.first.eventIdentifier.id, id)
    XCTAssertThrowsError(try fixture.native.probe.register(binding))
    try FileManager.default.removeItem(at: file); try before.write(to: file)
    try fixture.store.shortcuts.resetAll()
    XCTAssertNil(fixture.store.voicePreferences.globalHoldHotkey)
    XCTAssertEqual(fixture.store.shortcuts.binding("pet"), binding)
    XCTAssertEqual(fixture.pet.eventIdentifier.id, id)
  }

  private final class Counts { var first = 0; var second = 0; var firstRelease = 0; var secondRelease = 0 }
  private final class Window: NSWindow { override var isKeyWindow: Bool { true } }
  private func settle() async throws { try await Task.sleep(for: .milliseconds(60)) }
  private func send(_ kind: Int, _ eventIdentifier: EventHotKeyID) throws {
    var event: EventRef?
    XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kind), GetCurrentEventTime(), 0, &event), noErr)
    let value = try XCTUnwrap(event); defer { ReleaseEvent(value) }
    var identifier = eventIdentifier
    XCTAssertEqual(SetEventParameter(value, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
      MemoryLayout<EventHotKeyID>.size, &identifier), noErr)
    XCTAssertEqual(SendEventToEventTarget(value, GetApplicationEventTarget()), noErr)
  }

  @MainActor private final class StoreFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let native: Fixture
    let store: WorkspaceStore
    let pet = AppGlobalHotKey(id: 68_721, title: "宠物") {}
    let popout = AppGlobalHotKey(id: 68_722, title: "弹出窗口") {}
    init(controlledPetDefault: Bool = false) throws {
      native = try Fixture(); store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
      if controlledPetDefault {
        // Production defaults remain unchanged. Use a verified available native
        // combination to exercise the actual reset entry point deterministically.
        store.shortcuts = ShortcutPreferences(file: root.appendingPathComponent("shortcuts.json"),
          commandDefaults: ["pet": [native.bindings[0]]])
        store.connectShortcutSettingsStorage()
      }
      try store.shortcuts.set(nil, for: "pet")
      store.connectVoiceHotkeys(VoiceHotkeyRegistrationController(hold: native.first,
        toggle: native.second, voiceChat: native.third)) { _ in }
      CommandGlobalHotkeyRegistration(pet: pet, popout: popout).connect(to: store.shortcuts)
    }
    func saved() throws -> WorkspaceLibrary { try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json")) }
    func clean() {
      store.voiceHotkeyPreferenceCommitHandler = nil; store.voiceHotkeyRegistrationRetryHandler = nil
      store.globalDictationHotkeyChangeHandler = nil
      store.shortcuts.commitGlobalBindings = nil; store.shortcuts.retryGlobalRegistration = nil; store.shortcuts.didChange = nil
      try? FileManager.default.removeItem(at: root)
    }
  }

  @MainActor private final class Fixture {
    let first = AppGlobalHotKey(id: 68_701, title: "一") {}
    let second = AppGlobalHotKey(id: 68_702, title: "二") {}
    let third = AppGlobalHotKey(id: 68_703, title: "三") {}
    let probe = AppGlobalHotKey(id: 68_704, title: "探测") {}
    var bindings: [ShortcutBinding] = []
    init() throws {
      _ = NSApplication.shared
      for digit in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"] {
        let binding = ShortcutBinding("⌘⌃⌥⇧" + digit)
        do { try probe.register(binding); try probe.register(nil); bindings.append(binding) } catch { continue }
        if bindings.count == 4 { break }
      }
      guard bindings.count == 4 else { throw AgentFailure(message: "No four available test combinations") }
    }
  }
}
