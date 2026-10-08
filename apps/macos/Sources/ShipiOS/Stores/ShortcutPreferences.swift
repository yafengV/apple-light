import Foundation
import Observation

enum NumberShortcutTarget: String, Codable, CaseIterable {
  case tabs, sidebar
}

struct ShortcutPreferencesSnapshot: Codable {
  var version = 1
  var primaryNumberShortcutTarget: NumberShortcutTarget
  var overrides: [String: [ShortcutBinding]]
  var externalBrowserLinkShortcut: ExternalBrowserLinkShortcut?
}

@MainActor @Observable
final class ShortcutPreferences {
  @ObservationIgnored var commitGlobalBindings: ((CommandGlobalHotkeyBindings, CommandGlobalHotkeyBindings,
    () throws -> Void) throws -> Void)?
  @ObservationIgnored var retryGlobalRegistration: ((String) throws -> Void)?
  var globalRegistrationErrors: [String: String] = [:]
  @ObservationIgnored var voicePreferences: (() -> VoicePreferences)?
  @ObservationIgnored var voiceRegistrationError: ((VoiceShortcutPresentation.Mode) -> String?)?
  @ObservationIgnored var setVoiceBinding: ((VoiceShortcutPresentation.Mode, ShortcutBinding?) throws -> Void)?
  @ObservationIgnored var readSnapshot: (() throws -> ShortcutPreferencesSnapshot?)?
  @ObservationIgnored var persistSnapshot: ((ShortcutPreferencesSnapshot, Bool, () throws -> Void) throws -> Void)?
  @ObservationIgnored var didChange: ((String) -> Void)?
  private(set) var overrides: [String: [ShortcutBinding]] = [:]
  private(set) var primaryNumberShortcutTarget: NumberShortcutTarget = .tabs
  private(set) var externalBrowserLinkShortcut: ExternalBrowserLinkShortcut = .unassigned
  var hasCustomizations: Bool {
    !overrides.isEmpty || externalBrowserLinkShortcut != .unassigned
      || VoiceShortcutPresentation.Mode.allCases.contains { voicePreferences?()[$0] != nil }
  }
  func isCustomized(_ id: String) -> Bool {
    if VoiceShortcutPresentation.Mode(commandID: id) != nil { return binding(id) != nil }
    return overrides[id] != nil
  }
  private(set) var loadError: String?
  private let file: URL

  var snapshot: ShortcutPreferencesSnapshot {
    ShortcutPreferencesSnapshot(primaryNumberShortcutTarget: primaryNumberShortcutTarget,
      overrides: overrides, externalBrowserLinkShortcut: externalBrowserLinkShortcut)
  }
  func registrationError(_ id: String) -> String? {
    if let mode = VoiceShortcutPresentation.Mode(commandID: id) { return voiceRegistrationError?(mode) }
    return globalRegistrationErrors[id]
  }

  init(file: URL) {
    self.file = file
    reload()
  }

  /// Retry transient read failures without replacing the user's file.
  func reload() {
    do {
      if let snapshot = try readSnapshot?() {
        try restore(snapshot)
        return
      }
      let data = try Data(contentsOf: file)
      if let legacy = try? JSONDecoder().decode([String: [ShortcutBinding]].self, from: data) {
        overrides = legacy
        primaryNumberShortcutTarget = .tabs
        externalBrowserLinkShortcut = .unassigned
      } else {
        let loaded = try JSONDecoder().decode(ShortcutPreferencesSnapshot.self, from: data)
        try restore(loaded)
        return
      }
      loadError = nil
      didChange?("*")
    } catch CocoaError.fileReadNoSuchFile {
      overrides = [:]
      primaryNumberShortcutTarget = .tabs
      externalBrowserLinkShortcut = .unassigned
      loadError = nil
      didChange?("*")
    } catch { loadError = "无法读取快捷键设置：\(error.localizedDescription)" }
  }

  func restore(_ snapshot: ShortcutPreferencesSnapshot) throws {
    guard snapshot.version == 1 else { throw ShortcutError(message: "不支持此快捷键设置版本。") }
    overrides = snapshot.overrides
    primaryNumberShortcutTarget = snapshot.primaryNumberShortcutTarget
    externalBrowserLinkShortcut = snapshot.externalBrowserLinkShortcut ?? .unassigned
    loadError = nil
    didChange?("*")
  }

  func defaultBindings(_ id: String) -> [ShortcutBinding] {
    defaultBindings(id, target: primaryNumberShortcutTarget)
  }
  private func defaultBindings(_ id: String, target: NumberShortcutTarget) -> [ShortcutBinding] {
    if let slot = DesktopCommand.numberSlot(id) {
      let primary = slot.isTab == (target == .tabs)
      return [ShortcutBinding("\(primary ? "⌘" : "⌃")\(slot.index)")]
    }
    return DesktopCommand.all.first(where: { $0.id == id })?.defaultBindings ?? []
  }

  var hasNumberShortcutConflicts: Bool {
    DesktopCommand.all.contains {
      DesktopCommand.numberSlot($0.id) != nil && overrides[$0.id] == nil && bindings($0.id).isEmpty
    }
  }

  func setNumberShortcutTarget(_ target: NumberShortcutTarget) throws {
    guard target != primaryNumberShortcutTarget else { return }
    try persist(overrides, target: target)
    didChange?("*")
  }

  func setExternalBrowserLinkShortcut(_ shortcut: ExternalBrowserLinkShortcut) throws {
    guard shortcut != externalBrowserLinkShortcut else { return }
    try persist(overrides, linkShortcut: shortcut)
    didChange?("*")
  }

  func bindings(_ id: String) -> [ShortcutBinding] {
    if let mode = VoiceShortcutPresentation.Mode(commandID: id), let voicePreferences {
      return voicePreferences()[mode].map { [$0] } ?? []
    }
    return bindings(id, overrides: overrides, target: primaryNumberShortcutTarget)
  }
  private func bindings(_ id: String, overrides: [String: [ShortcutBinding]], target: NumberShortcutTarget) -> [ShortcutBinding] {
    if let custom = overrides[id] { return custom }
    let defaults = defaultBindings(id, target: target)
    // Every custom binding wins over newly introduced defaults, including aliases.
    return defaults.filter { binding in
      !overrides.contains { command, values in
        command != id && values.contains(binding) && DesktopCommand.all.contains { $0.id == command }
      }
    }
  }
  func binding(_ id: String) -> ShortcutBinding? { bindings(id).first }
  func matches(_ id: String, _ binding: ShortcutBinding) -> Bool { bindings(id).contains(binding) }
  func label(_ id: String) -> String { bindings(id).map(\.display).joined(separator: " / ") }
  func conflict(for binding: ShortcutBinding, excluding id: String) -> DesktopCommand? {
    DesktopCommand.all.first { command in
      guard command.id != id else { return false }
      return bindings(command.id).contains {
        $0 == binding || (command.allowsBareModifiers && binding.isBareModifier && $0.isBareModifier
          && (binding.modifierFlags.isSubset(of: $0.modifierFlags)
            || $0.modifierFlags.isSubset(of: binding.modifierFlags)))
      }
    }
  }
  func set(_ binding: ShortcutBinding?, for id: String) throws {
    try setBindings(binding.map { [$0] } ?? [], for: id)
  }
  func replace(_ old: ShortcutBinding?, with new: ShortcutBinding?, for id: String) throws {
    var values = bindings(id)
    if let old {
      guard let index = values.firstIndex(of: old) else {
        throw ShortcutError(message: "快捷键已更改，请重新选择要修改的绑定。")
      }
      if let new { values[index] = new } else { values.remove(at: index) }
    } else if let new { values.append(new) }
    try setBindings(values, for: id)
  }
  private func setBindings(_ values: [ShortcutBinding], for id: String) throws {
    guard DesktopCommand.all.contains(where: { $0.id == id }) else { return }
    if DesktopCommand.all.first(where: { $0.id == id })?.isOSGlobal == true, values.count > 1 {
      throw ShortcutError(message: "全局命令只能设置一个快捷键。")
    }
    guard values.count <= 6 else { throw ShortcutError(message: "每个命令最多设置 6 个快捷键。") }
    guard Set(values).count == values.count else { throw ShortcutError(message: "此命令已经使用这个快捷键。") }
    for binding in values {
      let petOptionBinding = id == "pet" && binding.option && !binding.command && !binding.control
        && (binding.key == "space" || binding.key.count == 1)
      if !petOptionBinding, let message = binding.validationMessage(for: id) {
        throw ShortcutError(message: message)
      }
      if let conflict = conflict(for: binding, excluding: id) {
        throw ShortcutError(message: "已用于“\(conflict.title)”，请先移除该命令的绑定。")
      }
    }
    if let mode = VoiceShortcutPresentation.Mode(commandID: id), let setVoiceBinding {
      try setVoiceBinding(mode, values.first)
      didChange?(id)
      return
    }
    var updated = overrides
    updated[id] = values
    try persist(updated)
    didChange?(id)
  }
  func reset(_ id: String) throws {
    if VoiceShortcutPresentation.Mode(commandID: id) != nil, setVoiceBinding != nil {
      try set(nil, for: id)
      return
    }
    for value in defaultBindings(id) {
      if let conflict = conflict(for: value, excluding: id) {
        throw ShortcutError(message: "默认快捷键已用于“\(conflict.title)”，请先移除该绑定。")
      }
    }
    var updated = overrides
    updated.removeValue(forKey: id)
    try persist(updated)
    didChange?(id)
  }
  func resetAll() throws { try persist([:], linkShortcut: .unassigned, resetVoice: true); didChange?("*") }
  private func persist(_ updated: [String: [ShortcutBinding]], target: NumberShortcutTarget? = nil,
    linkShortcut: ExternalBrowserLinkShortcut? = nil, resetVoice: Bool = false) throws {
    guard loadError == nil else { throw ShortcutError(message: loadError!) }
    let target = target ?? primaryNumberShortcutTarget
    let linkShortcut = linkShortcut ?? externalBrowserLinkShortcut
    if !resetVoice, let voice = voicePreferences?() {
      for command in DesktopCommand.all where !command.allowsBareModifiers {
        let previousBindings = bindings(command.id)
        for candidate in bindings(command.id, overrides: updated, target: target)
          where !previousBindings.contains(candidate) {
          if let conflict = VoiceShortcutPresentation.Mode.allCases.first(where: { voice[$0] == candidate }) {
            throw ShortcutError(message: "已用于“\(conflict.title)”，请先移除该绑定。")
          }
        }
      }
    }
    let previous = CommandGlobalHotkeyBindings(pet: binding("pet"), popout: binding("popout"))
    let next = CommandGlobalHotkeyBindings(
      pet: bindings("pet", overrides: updated, target: target).first,
      popout: bindings("popout", overrides: updated, target: target).first)
    let snapshot = ShortcutPreferencesSnapshot(primaryNumberShortcutTarget: target, overrides: updated,
      externalBrowserLinkShortcut: linkShortcut)
    let saveFile = {
      try FileManager.default.createDirectory(
        at: self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(snapshot)
        .write(to: self.file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.file.path)
    }
    let save = {
      if let persistSnapshot = self.persistSnapshot { try persistSnapshot(snapshot, resetVoice, saveFile) }
      else { try saveFile() }
      self.overrides = updated
      self.primaryNumberShortcutTarget = target
      self.externalBrowserLinkShortcut = linkShortcut
    }
    if let commitGlobalBindings { try commitGlobalBindings(previous, next, save) }
    else { try save() }
  }
}

private struct ShortcutError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
