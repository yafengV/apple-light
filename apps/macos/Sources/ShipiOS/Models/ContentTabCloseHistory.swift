import Foundation

/// Ephemeral opener relationships. These describe navigation intent, not durable
/// tab ownership, and must not be replayed when a workspace is restored cold.
struct ContentTabCloseHistory: Equatable {
  struct Entry: Equatable { let generation: Int; let openerTabID: String }
  private(set) var active = false
  private(set) var generation = 0
  private(set) var lastSelectedTabID: String?
  private(set) var tabs: [String: Entry] = [:]

  mutating func opened(_ id: String, by opener: String, background: Bool) {
    guard id != opener else { return }
    active = true
    if !background { lastSelectedTabID = opener }
    tabs[id] = Entry(generation: generation, openerTabID: opener)
  }

  mutating func selected(_ id: String?, in ids: [String]) {
    let previous = lastSelectedTabID
    lastSelectedTabID = id
    guard let id, tabs[id]?.generation == generation || ids.contains(where: {
      tabs[$0]?.openerTabID == id && tabs[$0]?.generation == generation
    }) else { invalidate(); return }
    guard let previous, previous != id,
      !descends(previous, from: id), !descends(id, from: previous) else { return }
    if root(of: previous) == root(of: id) { active = true }
    else { invalidate() }
  }

  func fallback(closing id: String, in ids: [String]) -> String? {
    guard let index = ids.firstIndex(of: id) else { return nil }
    if let entry = tabs[id], active, entry.generation == generation {
      if ids.contains(entry.openerTabID) { return entry.openerTabID }
      var after = false, before: String?
      for candidate in ids {
        if candidate == id { after = true; continue }
        if descends(candidate, from: entry.openerTabID), tabs[candidate]?.generation == generation {
          if after { return candidate }
          before = candidate
        }
      }
      if let before { return before }
    }
    return ids.dropFirst(index + 1).first ?? (index > 0 ? ids[index - 1] : nil)
  }

  mutating func removed(_ id: String) {
    var pending = [id]
    while let current = pending.popLast() {
      pending.append(contentsOf: tabs.compactMap { $0.value.openerTabID == current ? $0.key : nil })
      tabs[current] = nil
    }
    if tabs.isEmpty { active = false }
  }

  mutating func moved(_ id: String) {
    guard tabs[id] != nil || tabs.values.contains(where: { $0.openerTabID == id }) else { return }
    active = false; tabs = [:]; lastSelectedTabID = nil
  }

  private mutating func invalidate() { active = false; generation += 1 }
  private func descends(_ id: String, from ancestor: String) -> Bool {
    var current = id, seen = Set<String>()
    while seen.insert(current).inserted, let parent = tabs[current]?.openerTabID {
      if parent == ancestor { return true }
      current = parent
    }
    return false
  }
  private func root(of id: String) -> String {
    var current = id, seen = Set<String>()
    while seen.insert(current).inserted, let parent = tabs[current]?.openerTabID { current = parent }
    return current
  }
}

enum ContentTabClosePanel: Hashable {
  case primary, bottom, detached(String)
  init(_ placement: WorkspaceTabPlacement, id: String) {
    switch placement {
    case .left, .right: self = .primary
    case .bottom: self = .bottom
    case .detached: self = .detached(id)
    }
  }
}
struct ContentTabCloseScope: Hashable { let owner: String; let panel: ContentTabClosePanel }

struct ContentTabCloseController {
  var history = ContentTabCloseHistory()
  // Moving an opener family clears its history's lastSelectedTabID without
  // changing the controller's actual active tab.
  var selectedID: String?
  mutating func select(_ id: String?, in ids: [String]) {
    guard selectedID != id else { return }
    selectedID = id; history.selected(id, in: ids)
  }
  mutating func close(_ id: String, in ids: [String]) -> String? {
    guard ids.contains(id) else { return selectedID }
    if selectedID == id {
      select(history.fallback(closing: id, in: ids), in: ids.filter { $0 != id })
    }
    history.removed(id)
    return selectedID
  }
}
