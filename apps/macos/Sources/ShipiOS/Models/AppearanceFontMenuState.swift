import Foundation
import Observation

@MainActor @Observable final class AppearanceFontMenuState: SettingsPopupMenuState {
  enum Kind { case family, style }
  struct Option: Identifiable { let id: String; let title: String }
  let kind: Kind
  private(set) var presented = false
  var highlightedID: String?
  private(set) var options: [Option] = []
  private(set) var custom = false
  var draft = ""
  private var search = ""
  private var lastTypedAt: TimeInterval?
  init(_ kind: Kind) { self.kind = kind }
  func open(role: AppearanceFontRole, value: String, face: AppearanceFontFace?, families: [AppearanceFontCatalog.Family]?, keyboard: Bool) {
    custom = families?.isEmpty != false; draft = value
    switch kind {
    case .family:
      options = [.init(id: "default", title: role.defaultTitle)]
      if custom { options.append(.init(id: "custom", title: "使用自定义字体值")) }
      else { options += (families ?? []).filter { role != .code || $0.faces.allSatisfy(\.monospaced) }
        .map { .init(id: "family:" + $0.name, title: $0.name) } }
    case .style:
      guard let resolved = AppearanceFontCatalog.resolve(value, face: face, families: families),
        role != .code || resolved.family.faces.allSatisfy(\.monospaced) else { return }
      options = resolved.family.faces.map { .init(id: "face:" + $0.value.postscriptName, title: $0.style) }
    }
    presented = true; highlightedID = keyboard ? options.first?.id : nil; search = ""; lastTypedAt = nil
  }
  var height: CGFloat { min(350, CGFloat(options.count * 26) + 8 + (kind == .family ? 9 : 0) + (kind == .family && custom ? 28 : 0)) }
  func dismiss() { presented = false; highlightedID = nil; search = ""; lastTypedAt = nil }
  func move(_ delta: Int) {
    guard presented, !options.isEmpty else { return }
    let index = highlightedID.flatMap { id in options.firstIndex { $0.id == id } }
    highlightedID = options[index.map { max(0, min(options.count - 1, $0 + delta)) } ?? (delta < 0 ? options.count - 1 : 0)].id
  }
  func edge(last: Bool) { guard presented else { return }; highlightedID = last ? options.last?.id : options.first?.id }
  func hover(_ id: String?) { guard presented, id == nil || options.contains(where: { $0.id == id }) else { return }; highlightedID = id }
  func type(_ character: String, now: TimeInterval) {
    guard presented else { return }
    if lastTypedAt.map({ now - $0 >= 1 }) != false { search = "" }
    search += character; lastTypedAt = now
    let chars = Array(search)
    let pattern = chars.count > 1 && chars.allSatisfy({ $0 == chars.first }) ? String(chars[0]) : search
    let start = highlightedID.flatMap { id in options.firstIndex { $0.id == id } } ?? 0
    for index in 0..<options.count {
      let candidate = options[(start + index) % options.count]
      if !(pattern.utf16.count == 1 && candidate.id == highlightedID), candidate.title.lowercased().hasPrefix(pattern.lowercased()) {
        highlightedID = candidate.id; break
      }
    }
  }
  func space(now: TimeInterval) -> Bool {
    guard presented else { return false }
    if lastTypedAt.map({ now - $0 < 1 }) == true, !search.isEmpty { type(" ", now: now); return false }; return true
  }
  @discardableResult func choose(_ id: String, role: AppearanceFontRole, dark: Bool, value: String,
    face: AppearanceFontFace?, families: [AppearanceFontCatalog.Family]?, store: WorkspaceStore) -> Bool {
    guard presented, options.contains(where: { $0.id == id }), store.libraryLoaded, !store.restoringLibrary else { return false }
    let resolved = AppearanceFontCatalog.resolve(value, face: face, families: families)
    if id == "default" {
      if !value.isEmpty || face != nil { _ = store.setAppearanceFont(role, family: nil, dark: dark) }
    } else if id == "custom", custom {
      let next = AppearanceFontFamily.trimmed(draft)
      if next != value || face != nil { _ = store.setAppearanceFont(role, family: next.isEmpty ? nil : next, dark: dark) }
    } else if kind == .family, let family = families?.first(where: { "family:" + $0.name == id }), !family.faces.isEmpty {
      if family.name != resolved?.family.name {
        _ = store.setAppearanceFont(role, family: AppearanceFontCatalog.quote(family.name), face: nil, dark: dark)
      }
    } else if kind == .style, let resolved, let selected = resolved.family.faces.first(where: { "face:" + $0.value.postscriptName == id }) {
      if selected.value.postscriptName != resolved.face.value.postscriptName {
        _ = store.setAppearanceFont(role, family: AppearanceFontCatalog.quote(resolved.family.name),
          face: selected.value.postscriptName == resolved.family.faces.first?.value.postscriptName ? nil : selected.value, dark: dark)
      }
    } else { return false }
    dismiss(); return true
  }
}
