import AppKit

struct VoiceBareModifierState {
  enum Action: Equatable { case pressHold, releaseHold, toggle }

  private var activeHold: ShortcutBinding?
  private var heldToggle: ShortcutBinding?
  private var armed = true
  private static let mask: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

  mutating func flagsChanged(_ flags: NSEvent.ModifierFlags,
    hold: ShortcutBinding?, toggle: ShortcutBinding?) -> [Action] {
    let current = flags.intersection(Self.mask)
    if !armed {
      if current.isEmpty { armed = true }
      return []
    }
    var actions: [Action] = []
    if let activeHold, current != activeHold.modifierFlags {
      self.activeHold = nil
      actions.append(.releaseHold)
    }
    if let heldToggle, current != heldToggle.modifierFlags { self.heldToggle = nil }
    if let hold, hold.isBareModifier, current == hold.modifierFlags, activeHold == nil {
      activeHold = hold
      actions.append(.pressHold)
    }
    if let toggle, toggle.isBareModifier, current == toggle.modifierFlags, heldToggle == nil {
      heldToggle = toggle
      actions.append(.toggle)
    }
    return actions
  }

  mutating func keyDown(currentFlags: NSEvent.ModifierFlags) -> [Action] {
    armed = currentFlags.intersection(Self.mask).isEmpty
    heldToggle = nil
    guard activeHold != nil else { return [] }
    activeHold = nil
    return [.releaseHold]
  }

  mutating func reset(currentFlags: NSEvent.ModifierFlags) -> [Action] {
    let release: [Action] = activeHold == nil ? [] : [.releaseHold]
    activeHold = nil
    heldToggle = nil
    armed = currentFlags.intersection(Self.mask).isEmpty
    return release
  }
}
