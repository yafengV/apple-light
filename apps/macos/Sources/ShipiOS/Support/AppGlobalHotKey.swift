import Carbon.HIToolbox
import Foundation

@MainActor
final class AppGlobalHotKey {
  private var native: NativeRegistration?
  private let primaryRoute: GlobalHotkeyEventRoute
  private var registeredBinding: ShortcutBinding?
  private enum PressRoute { case idle, action, capture }
  private var pressRoute = PressRoute.idle
  private var registrationRevision: UInt64 = 0
  private let action: () -> Void
  private let releaseAction: (() -> Void)?
  private let title: String
  private let allowsRepeat: Bool

  init(id: UInt32, title: String, allowsRepeat: Bool = true, onRelease: (() -> Void)? = nil,
    action: @escaping () -> Void) {
    primaryRoute = GlobalHotkeyEventRoute.make(preferredID: id)
    self.title = title
    self.allowsRepeat = allowsRepeat
    self.action = action
    releaseAction = onRelease
    primaryRoute.owner = self
  }

  var eventIdentifier: EventHotKeyID { (native?.route ?? primaryRoute).identifier }

  func delivery(released: Bool) -> (@MainActor () -> Void) {
    if released {
      let invoke = pressRoute != .capture
      pressRoute = .idle
      return { if invoke { self.releaseAction?() } }
    }
    guard pressRoute != .capture else { return {} }
    if pressRoute == .action, !allowsRepeat { return {} }
    let revision = registrationRevision
    if let recorder = ShortcutCapture.Field.currentRecorder() {
      pressRoute = .capture
      let capture = registeredBinding.flatMap { recorder.registeredKeyDelivery($0) }
      return {
        guard self.registrationRevision == revision else { return }
        capture?()
      }
    }
    pressRoute = .action
    let routing = ShortcutCapture.Field.routingRevision
    return {
      guard self.registrationRevision == revision,
        ShortcutCapture.Field.routingRevision == routing else { return }
      self.action()
    }
  }

  func register(_ binding: ShortcutBinding?) throws {
    try prepareRegistration(binding).commit()
  }

  /// Keep all old registrations until saving succeeds. A group can reuse a
  /// registration released by another member without opening an OS race window.
  func prepareRegistration(_ binding: ShortcutBinding?) throws -> PreparedRegistration {
    do { return try Self.prepareRegistrations([(self, binding)]) }
    catch let failure as PreparationFailure { throw failure.underlying }
  }

  struct PreparationFailure: LocalizedError {
    let index: Int
    let underlying: Error
    var errorDescription: String? { underlying.localizedDescription }
  }

  static func prepareRegistrations(_ changes: [(AppGlobalHotKey, ShortcutBinding?)]) throws -> PreparedRegistration {
    var seenOwners: Set<ObjectIdentifier> = [], seenBindings: Set<ShortcutBinding> = []
    for (index, change) in changes.enumerated() {
      guard seenOwners.insert(ObjectIdentifier(change.0)).inserted,
        change.1.map({ seenBindings.insert($0).inserted }) ?? true else {
        throw PreparationFailure(index: index, underlying: AgentFailure(message: "同一批全局快捷键不能重复分配。"))
      }
    }
    let reused = changes.map { owner, binding -> NativeRegistration? in
      guard let binding else { return nil }
      return changes.first(where: { $0.0.native?.binding == binding })?.0.native
    }
    let transferred = Set(zip(changes, reused).compactMap { change, candidate -> ObjectIdentifier? in
      guard let candidate, change.0.native !== candidate else { return nil }
      return ObjectIdentifier(candidate)
    })
    var entries: [PreparedRegistration.Entry] = []
    for (index, change) in changes.enumerated() {
      let (owner, binding) = change
      if binding == owner.registeredBinding {
        entries.append(.init(owner: owner, binding: binding, candidate: owner.native, changes: false))
        continue
      }
      var candidate = reused[index]
      if let binding, candidate == nil {
        let currentRoute = owner.native?.route ?? owner.primaryRoute
        let donated = owner.native.map { transferred.contains(ObjectIdentifier($0)) } ?? false
        let route = !donated && (currentRoute.owner === owner || currentRoute.owner == nil)
          ? currentRoute : GlobalHotkeyEventRoute.make()
        route.owner = owner
        do { candidate = try NativeRegistration(binding: binding, route: route, title: owner.title) }
        catch { throw PreparationFailure(index: index, underlying: error) }
      }
      entries.append(.init(owner: owner, binding: binding, candidate: candidate, changes: true))
    }
    return PreparedRegistration(entries: entries)
  }

  @MainActor fileprivate final class NativeRegistration {
    let binding: ShortcutBinding
    let route: GlobalHotkeyEventRoute
    private var reference: EventHotKeyRef?
    init(binding: ShortcutBinding, route: GlobalHotkeyEventRoute, title: String) throws {
      self.binding = binding; self.route = route
      guard route.handler != nil else {
        throw AgentFailure(message: "无法安装\(title)全局快捷键的事件处理器。")
      }
      guard let keyCode = AppGlobalHotKey.keyCode(binding.key) else {
        throw AgentFailure(message: "\(title)全局快捷键不支持这个按键。")
      }
      var modifiers: UInt32 = 0
      if binding.command { modifiers |= UInt32(cmdKey) }
      if binding.control { modifiers |= UInt32(controlKey) }
      if binding.option { modifiers |= UInt32(optionKey) }
      if binding.shift { modifiers |= UInt32(shiftKey) }
      let status = RegisterEventHotKey(keyCode, modifiers, route.identifier, GetApplicationEventTarget(), 0, &reference)
      guard status == noErr else {
        throw AgentFailure(message: "无法注册\(title)全局快捷键，可能已被其他应用占用。")
      }
    }
    deinit { if let reference { UnregisterEventHotKey(reference) } }
  }

  @MainActor final class PreparedRegistration {
    fileprivate struct Entry {
      let owner: AppGlobalHotKey
      let binding: ShortcutBinding?
      let candidate: NativeRegistration?
      let changes: Bool
    }
    private var entries: [Entry]
    private var committed = false
    fileprivate init(entries: [Entry]) { self.entries = entries }
    func commit() {
      guard !committed else { return }
      committed = true
      let previous = entries.compactMap { $0.owner.native }
      for entry in entries where entry.changes {
        entry.owner.native = entry.candidate
        entry.owner.registeredBinding = entry.binding
        entry.owner.registrationRevision &+= 1
      }
      for entry in entries where entry.changes { entry.candidate?.route.owner = entry.owner }
      entries.removeAll()
      // Reused references now have their new owner; release only unused ones.
      withExtendedLifetime(previous) {}
    }
  }

  private static func keyCode(_ key: String) -> UInt32? {
    let codes: [String: Int] = [
      "a": kVK_ANSI_A, "s": kVK_ANSI_S, "d": kVK_ANSI_D, "f": kVK_ANSI_F,
      "h": kVK_ANSI_H, "g": kVK_ANSI_G, "z": kVK_ANSI_Z, "x": kVK_ANSI_X,
      "c": kVK_ANSI_C, "v": kVK_ANSI_V, "b": kVK_ANSI_B, "q": kVK_ANSI_Q,
      "w": kVK_ANSI_W, "e": kVK_ANSI_E, "r": kVK_ANSI_R, "y": kVK_ANSI_Y,
      "t": kVK_ANSI_T, "o": kVK_ANSI_O, "u": kVK_ANSI_U, "i": kVK_ANSI_I,
      "p": kVK_ANSI_P, "l": kVK_ANSI_L, "j": kVK_ANSI_J, "k": kVK_ANSI_K,
      "n": kVK_ANSI_N, "m": kVK_ANSI_M,
      "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
      "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
      "8": kVK_ANSI_8, "9": kVK_ANSI_9,
      "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket,
      "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash, ";": kVK_ANSI_Semicolon,
      "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
      "/": kVK_ANSI_Slash, "`": kVK_ANSI_Grave,
      "space": kVK_Space, "↵": kVK_Return,
      "⇥": kVK_Tab, "⎋": kVK_Escape, "←": kVK_LeftArrow, "→": kVK_RightArrow,
      "↓": kVK_DownArrow, "↑": kVK_UpArrow,
    ]
    return codes[key].map(UInt32.init)
  }
}
