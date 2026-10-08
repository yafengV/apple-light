import Foundation

/// The general shortcuts page groups the two dictation commands separately.
/// A search that only finds single-tap (or a keystroke search) reveals it
/// directly without changing the user's temporary advanced disclosure state.
struct ShortcutDictationGroup {
  static let holdID = "globalDictationHold"
  static let toggleID = "globalDictationSingleTap"
  let ordinaryCommandIDs: [String]
  let holdMatches: Bool
  let toggleMatches: Bool
  let searching: Bool
  let expanded: Bool
  var showsCard: Bool { holdMatches || toggleMatches }
  var showsSingleTap: Bool { toggleMatches && (searching || expanded) }
  var showsAdvanced: Bool { toggleMatches && !searching }

  init(commandIDs: [String], query: String, searchByKeys: Bool, expanded: Bool) {
    ordinaryCommandIDs = commandIDs.filter { $0 != Self.holdID && $0 != Self.toggleID }
    holdMatches = commandIDs.contains(Self.holdID)
    toggleMatches = commandIDs.contains(Self.toggleID)
    searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!holdMatches || searchByKeys)
    self.expanded = expanded
  }
}
