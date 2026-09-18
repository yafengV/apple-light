import Foundation

extension WorkspaceStore {
  func loadMemories() async {
    guard !memoriesLoading else { return }
    memoriesLoading = true
    defer { memoriesLoading = false }
    let root = dataRoot
    memoriesLoaded = false
    do {
      memoryPreferences = try await Task.detached(priority: .userInitiated) {
        try MemoryStorage.load(root: root)
      }.value
      memoriesLoaded = true
      memoryError = nil
    } catch {
      memoryError = error.localizedDescription
    }
  }

  @discardableResult func saveMemoryEnabled(_ enabled: Bool) -> Bool {
    mutateMemories { $0.enabled = enabled }
  }

  @discardableResult func addMemory(_ text: String) -> Bool {
    do {
      let value = try MemoryStorage.normalizedText(text)
      let succeeded = mutateMemories { preferences in
        guard !preferences.items.contains(where: { $0.text == value }) else {
          throw AgentFailure(message: "这条记忆已经存在。")
        }
        preferences.items.append(SavedMemory(text: value))
      }
      if succeeded { memoryDraft = "" }
      return succeeded
    } catch {
      memoryError = error.localizedDescription
      return false
    }
  }

  @discardableResult func updateMemory(_ id: UUID, text: String) -> Bool {
    do {
      let value = try MemoryStorage.normalizedText(text)
      return mutateMemories { preferences in
        guard let index = preferences.items.firstIndex(where: { $0.id == id }) else {
          throw AgentFailure(message: "找不到要更新的记忆。")
        }
        guard !preferences.items.contains(where: { $0.id != id && $0.text == value }) else {
          throw AgentFailure(message: "这条记忆已经存在。")
        }
        preferences.items[index].text = value
        preferences.items[index].updatedAt = Date()
      }
    } catch {
      memoryError = error.localizedDescription
      return false
    }
  }

  @discardableResult func deleteMemory(_ id: UUID) -> Bool {
    mutateMemories { preferences in
      guard preferences.items.contains(where: { $0.id == id }) else {
        throw AgentFailure(message: "找不到要删除的记忆。")
      }
      preferences.items.removeAll { $0.id == id }
    }
  }

  @discardableResult func clearMemories() -> Bool {
    mutateMemories { $0.items.removeAll() }
  }

  /// Delete only the exact records the user saw when opening confirmation.
  @discardableResult func deleteMemories(_ expected: [SavedMemory]) -> Bool {
    mutateMemories { preferences in
      let ids = Set(expected.map(\.id))
      guard !expected.isEmpty, expected.allSatisfy({ preferences.items.contains($0) }) else {
        throw AgentFailure(message: "记忆内容已变化，请取消后重新选择。")
      }
      preferences.items.removeAll { ids.contains($0.id) }
    }
  }

  private func mutateMemories(_ mutation: (inout MemoryPreferences) throws -> Void) -> Bool {
    guard memoriesLoaded else { return false }
    do {
      var updated = memoryPreferences
      try mutation(&updated)
      try MemoryStorage.save(updated, root: dataRoot)
      memoryPreferences = updated
      memoryError = nil
      return true
    } catch {
      memoryError = error.localizedDescription
      return false
    }
  }
}
