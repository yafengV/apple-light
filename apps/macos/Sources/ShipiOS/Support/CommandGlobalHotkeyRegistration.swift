import Foundation

struct CommandGlobalHotkeyBindings: Equatable {
  var pet: ShortcutBinding?
  var popout: ShortcutBinding?
  subscript(_ id: String) -> ShortcutBinding? { id == "pet" ? pet : popout }
  static let commandIDs = ["pet", "popout"]
}

struct CommandGlobalHotkeyFailure: LocalizedError {
  let commandID: String
  let message: String
  var errorDescription: String? { message }
}

/// Registers candidates before saving, then replaces both native bindings only
/// after the save succeeds. Restored failures remain local to their command.
@MainActor final class CommandGlobalHotkeyRegistration {
  private let keys: [String: AppGlobalHotKey]
  private var registered: [String: ShortcutBinding] = [:]
  private var errors: [String: String] = [:]

  init(pet: AppGlobalHotKey, popout: AppGlobalHotKey) {
    keys = ["pet": pet, "popout": popout]
  }

  func commit(_ next: CommandGlobalHotkeyBindings, replacing previous: CommandGlobalHotkeyBindings,
    persist: () throws -> Void) throws {
    var prepared: [(String, AppGlobalHotKey.PreparedRegistration)] = []
    for id in CommandGlobalHotkeyBindings.commandIDs where next[id] != previous[id] {
      do { prepared.append((id, try keys[id]!.prepareRegistration(next[id]))) }
      catch {
        errors[id] = error.localizedDescription
        throw CommandGlobalHotkeyFailure(commandID: id, message: error.localizedDescription)
      }
    }
    try persist()
    for (id, candidate) in prepared {
      candidate.commit(); registered[id] = next[id]; errors[id] = nil
    }
  }

  func connect(to preferences: ShortcutPreferences) {
    preferences.commitGlobalBindings = { [weak preferences] previous, next, persist in
      do {
        try self.commit(next, replacing: previous, persist: persist)
        for id in CommandGlobalHotkeyBindings.commandIDs where next[id] != previous[id] {
          preferences?.globalRegistrationErrors[id] = nil
        }
      } catch let failure as CommandGlobalHotkeyFailure {
        preferences?.globalRegistrationErrors[failure.commandID] = failure.message
        throw failure
      }
    }
    let refresh: (String?, Bool) throws -> Void = { [weak preferences] id, force in
      guard let preferences else { return }
      var failure: CommandGlobalHotkeyFailure?
      for commandID in CommandGlobalHotkeyBindings.commandIDs where id == nil || commandID == id {
        let binding = preferences.binding(commandID)
        guard force || self.registered[commandID] != binding || self.errors[commandID] != nil else { continue }
        do {
          try self.keys[commandID]!.register(binding)
          self.registered[commandID] = binding; self.errors[commandID] = nil
          preferences.globalRegistrationErrors[commandID] = nil
        } catch {
          self.errors[commandID] = error.localizedDescription
          preferences.globalRegistrationErrors[commandID] = error.localizedDescription
          failure = CommandGlobalHotkeyFailure(commandID: commandID, message: error.localizedDescription)
        }
      }
      if let failure { throw failure }
    }
    preferences.didChange = { id in
      guard id == "*" || CommandGlobalHotkeyBindings.commandIDs.contains(id) else { return }
      try? refresh(id == "*" ? nil : id, false)
    }
    preferences.retryGlobalRegistration = { id in try refresh(id, true) }
    try? refresh(nil, false)
  }
}
