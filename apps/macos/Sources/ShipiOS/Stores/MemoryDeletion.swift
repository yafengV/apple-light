import Foundation

extension WorkspaceStore {
  func requestMemoryDeletion(_ id: UUID? = nil) {
    guard destination == .settings, settingsPage == .memories, memoriesLoaded,
      !hasSettingsConfirmation, presentedOverlay == nil else { return }
    let items = memoryPreferences.items.filter { id == nil || $0.id == id }
    guard !items.isEmpty else { return }
    memoryDeletionError = nil
    memoryDeletion = MemoryDeletionRequest(kind: id == nil ? .all : .single, items: items)
  }

  func dismissMemoryDeletion() {
    guard !deletingMemories else { return }
    memoryDeletion = nil
    memoryDeletionError = nil
  }

  func confirmMemoryDeletion() async {
    guard let request = memoryDeletion, !deletingMemories else { return }
    deletingMemories = true
    defer { deletingMemories = false }
    await Task.yield()
    guard memoriesLoaded else {
      memoryDeletionError = "记忆尚未成功加载，请取消后重新加载。"
      return
    }
    if deleteMemories(request.items) {
      memoryDeletion = nil
      memoryDeletionError = nil
      notices.show(id: "memory-deletion", title: "已删除记忆", level: .info)
    } else {
      memoryDeletionError = memoryError ?? "无法删除记忆，请重试。"
    }
  }
}
