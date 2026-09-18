import Foundation
import IOKit.pwr_mgt
import Observation

protocol IdleSleepAssertion: AnyObject {
  func release() throws
}

/// Only prevents idle system sleep; it does not keep the display lit or unlock the Mac.
final class SystemIdleSleepAssertion: IdleSleepAssertion {
  private(set) var id: IOPMAssertionID?

  init(name: String = "ShipiOS task running") throws {
    var created: IOPMAssertionID = 0
    let status = IOPMAssertionCreateWithName(
      kIOPMAssertPreventUserIdleSystemSleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &created)
    guard status == kIOReturnSuccess else {
      throw AgentFailure(message: "无法阻止空闲休眠（系统错误 \(status)）。")
    }
    id = created
  }

  func release() throws {
    guard let id else { return }
    let status = IOPMAssertionRelease(id)
    guard status == kIOReturnSuccess || status == kIOReturnNotFound else {
      throw AgentFailure(message: "无法释放防休眠状态（系统错误 \(status)）。")
    }
    self.id = nil
  }

  deinit {
    if let id { IOPMAssertionRelease(id) }
  }
}

@MainActor @Observable final class SleepPrevention {
  private(set) var active = false
  var error: String?
  @ObservationIgnored private var assertion: (any IdleSleepAssertion)?
  @ObservationIgnored private var lastDesired: Bool?
  @ObservationIgnored private let makeAssertion: () throws -> any IdleSleepAssertion

  init(makeAssertion: (() throws -> any IdleSleepAssertion)? = nil) {
    self.makeAssertion = makeAssertion ?? { try SystemIdleSleepAssertion() }
  }

  func update(enabled: Bool, hasRunningWork: Bool, force: Bool = false) {
    let desired = enabled && hasRunningWork
    guard force || lastDesired != desired else { return }
    lastDesired = desired
    do {
      if desired {
        if assertion == nil { assertion = try makeAssertion() }
        active = true
      } else {
        try assertion?.release()
        assertion = nil
        active = false
      }
      error = nil
    } catch { self.error = error.localizedDescription }
  }

  func stop() { update(enabled: false, hasRunningWork: false, force: true) }
}
