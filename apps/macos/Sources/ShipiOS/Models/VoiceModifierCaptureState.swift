import AppKit

struct VoiceModifierCaptureState {
  private var observed: NSEvent.ModifierFlags = []
  private static let mask: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

  mutating func flagsChanged(_ flags: NSEvent.ModifierFlags) -> ShortcutBinding? {
    let current = flags.intersection(Self.mask)
    if !current.isEmpty {
      observed.formUnion(current)
      return nil
    }
    defer { observed = [] }
    return observed.isEmpty ? nil : ShortcutBinding(modifiers: observed)
  }

  mutating func reset() { observed = [] }
}
