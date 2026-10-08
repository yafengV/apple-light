import AppKit
import XCTest
@testable import ShipiOS

@MainActor final class GlobalHotkeyRegistrationTests: XCTestCase {
  func testOccupiedReplacementKeepsOriginalCarbonRegistration() throws {
    _ = NSApplication.shared
    let owner = AppGlobalHotKey(id: 68_201, title: "原绑定") {}
    let blocker = AppGlobalHotKey(id: 68_202, title: "占用组合") {}
    let probe = AppGlobalHotKey(id: 68_203, title: "探测") {}
    let bindings = try availableBindings(probe, count: 2)
    try owner.register(bindings[0]); try blocker.register(bindings[1])
    XCTAssertThrowsError(try owner.register(bindings[1]))
    XCTAssertThrowsError(try probe.register(bindings[0]), "失败后原组合仍应被原对象持有")
    try owner.register(nil)
    XCTAssertNoThrow(try probe.register(bindings[0]))
    withExtendedLifetime(blocker) {}
  }

  func testUnsupportedReplacementKeepsOriginalCarbonRegistration() throws {
    _ = NSApplication.shared
    let owner = AppGlobalHotKey(id: 68_204, title: "原绑定") {}
    let probe = AppGlobalHotKey(id: 68_205, title: "探测") {}
    let binding = try XCTUnwrap(availableBindings(probe, count: 1).first)
    try owner.register(binding)
    XCTAssertThrowsError(try owner.register(ShortcutBinding("⌃⌥⇧😀")))
    XCTAssertThrowsError(try probe.register(binding), "按键解码失败不得撤销原组合")
    try owner.register(nil)
    XCTAssertNoThrow(try probe.register(binding))
  }

  func testSuccessfulReplacementReleasesOnlyPreviousCombinationAndIdenticalRefreshKeepsNewOne() throws {
    _ = NSApplication.shared
    let owner = AppGlobalHotKey(id: 68_206, title: "原绑定") {}
    let probe = AppGlobalHotKey(id: 68_207, title: "探测") {}
    let bindings = try availableBindings(probe, count: 2)
    try owner.register(bindings[0]); try owner.register(bindings[1])
    XCTAssertNoThrow(try probe.register(bindings[0])); try probe.register(nil)
    XCTAssertThrowsError(try probe.register(bindings[1]))
    XCTAssertNoThrow(try owner.register(bindings[1]))
    XCTAssertThrowsError(try probe.register(bindings[1]))
    try owner.register(nil)
    XCTAssertNoThrow(try probe.register(bindings[1]))
  }

  func testDiscardedPreparationKeepsOriginalAndReleasesCandidate() throws {
    _ = NSApplication.shared
    let owner = AppGlobalHotKey(id: 68_208, title: "原绑定") {}
    let probe = AppGlobalHotKey(id: 68_209, title: "探测") {}
    let bindings = try availableBindings(probe, count: 2)
    try owner.register(bindings[0])
    do {
      let prepared = try owner.prepareRegistration(bindings[1])
      XCTAssertThrowsError(try probe.register(bindings[0]))
      XCTAssertThrowsError(try probe.register(bindings[1]))
      withExtendedLifetime(prepared) {}
    }
    XCTAssertThrowsError(try probe.register(bindings[0]))
    XCTAssertNoThrow(try probe.register(bindings[1]))
  }

  func testDiscardedClearPreparationDoesNotReleaseOriginal() throws {
    _ = NSApplication.shared
    let owner = AppGlobalHotKey(id: 68_210, title: "原绑定") {}
    let probe = AppGlobalHotKey(id: 68_211, title: "探测") {}
    let binding = try XCTUnwrap(availableBindings(probe, count: 1).first)
    try owner.register(binding)
    do { let clear = try owner.prepareRegistration(nil); withExtendedLifetime(clear) {} }
    XCTAssertThrowsError(try probe.register(binding))
    let clear = try owner.prepareRegistration(nil); clear.commit(); clear.commit()
    XCTAssertNoThrow(try probe.register(binding))
  }

  private func availableBindings(_ probe: AppGlobalHotKey, count: Int) throws -> [ShortcutBinding] {
    var bindings: [ShortcutBinding] = []
    for key in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"] {
      let binding = try XCTUnwrap(ShortcutBinding("⌘⌃⌥⇧" + key))
      do { try probe.register(binding); try probe.register(nil); bindings.append(binding) }
      catch { continue }
      if bindings.count == count { return bindings }
    }
    XCTFail("本机没有足够可注册的测试组合，不能以跳过代替真实 Carbon 验证")
    return bindings
  }
}
