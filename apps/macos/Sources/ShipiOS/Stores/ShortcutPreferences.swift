import Foundation
import Observation

enum NumberShortcutTarget: String, Codable, CaseIterable {
  case tabs, sidebar
}

private struct SavedShortcuts: Codable {
  var version = 1
  var primaryNumberShortcutTarget: NumberShortcutTarget
  var overrides: [String: [ShortcutBinding]]
  var externalBrowserLinkShortcut: ExternalBrowserLinkShortcut?
}

@MainActor @Observable
final class ShortcutPreferences {
  @ObservationIgnored var didChange: ((String) -> Void)?
  private(set) var overrides: [String: [ShortcutBinding]] = [:]
  private(set) var primaryNumberShortcutTarget: NumberShortcutTarget = .tabs
  private(set) var externalBrowserLinkShortcut: ExternalBrowserLinkShortcut = .unassigned
  var hasCustomizations: Bool { !overrides.isEmpty || externalBrowserLinkShortcut != .unassigned }
  private(set) var loadError: String?
  private let file: URL

  init(file: URL) {
    self.file = file
    reload()
  }

  /// Retry transient read failures without replacing the user's file.
  func reload() {
    do {
      let data = try Data(contentsOf: file)
      if let legacy = try? JSONDecoder().decode([String: [ShortcutBinding]].self, from: data) {
        overrides = legacy
        primaryNumberShortcutTarget = .tabs
        externalBrowserLinkShortcut = .unassigned
      } else {
        let loaded = try JSONDecoder().decode(SavedShortcuts.self, from: data)
        guard loaded.version == 1 else { throw ShortcutError(message: "不支持此快捷键设置版本。") }
        overrides = loaded.overrides
        primaryNumberShortcutTarget = loaded.primaryNumberShortcutTarget
        externalBrowserLinkShortcut = loaded.externalBrowserLinkShortcut ?? .unassigned
      }
      loadError = nil
    } catch CocoaError.fileReadNoSuchFile {
      overrides = [:]
      primaryNumberShortcutTarget = .tabs
      externalBrowserLinkShortcut = .unassigned
      loadError = nil
    } catch { loadError = "无法读取快捷键设置：\(error.localizedDescription)" }
  }

  func defaultBindings(_ id: String) -> [ShortcutBinding] {
    if let slot = DesktopCommand.numberSlot(id) {
      let primary = slot.isTab == (primaryNumberShortcutTarget == .tabs)
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
    if let custom = overrides[id] { return custom }
    let defaults = defaultBindings(id)
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
    DesktopCommand.all.first { $0.id != id && matches($0.id, binding) }
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
    var updated = overrides
    updated[id] = values
    try persist(updated)
    didChange?(id)
  }
  func reset(_ id: String) throws {
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
  func resetAll() throws { try persist([:], linkShortcut: .unassigned); didChange?("*") }
  private func persist(_ updated: [String: [ShortcutBinding]], target: NumberShortcutTarget? = nil,
    linkShortcut: ExternalBrowserLinkShortcut? = nil) throws {
    guard loadError == nil else { throw ShortcutError(message: loadError!) }
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let target = target ?? primaryNumberShortcutTarget
    let linkShortcut = linkShortcut ?? externalBrowserLinkShortcut
    try JSONEncoder().encode(SavedShortcuts(primaryNumberShortcutTarget: target, overrides: updated,
      externalBrowserLinkShortcut: linkShortcut))
      .write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    overrides = updated
    primaryNumberShortcutTarget = target
    externalBrowserLinkShortcut = linkShortcut
  }
}

private struct ShortcutError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
