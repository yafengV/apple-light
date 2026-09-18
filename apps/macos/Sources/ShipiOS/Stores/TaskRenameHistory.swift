import Foundation
import Observation

@MainActor @Observable final class TaskRenameHistory {
  struct Entry {
    let taskID: String
    let before: String
    let after: String
    var expiresAt: Date
  }
  private(set) var undoEntries: [Entry] = []
  private(set) var redoEntries: [Entry] = []
  var message: String?
  var failed = false
  var nextExpiration: Date? { (undoEntries + redoEntries).map(\.expiresAt).min() }

  func rename(store: WorkspaceStore, taskID: String, title: String, now: Date = Date()) throws {
    let before = store.library.tasks.first { $0.id == taskID }?.title
    try store.renameTask(taskID, title: title)
    guard let before, let after = store.library.tasks.first(where: { $0.id == taskID })?.title,
      before != after else { return }
    expire(now: now)
    undoEntries.append(Entry(taskID: taskID, before: before, after: after, expiresAt: now.addingTimeInterval(60)))
    redoEntries.removeAll()
    message = nil
  }

  func expire(now: Date = Date()) {
    undoEntries.removeAll { $0.expiresAt <= now }
    redoEntries.removeAll { $0.expiresAt <= now }
  }

  func canPerform(redo: Bool, store: WorkspaceStore, now: Date = Date()) -> Bool {
    guard let entry = (redo ? redoEntries : undoEntries).last, entry.expiresAt > now,
      let task = store.library.tasks.first(where: { $0.id == entry.taskID }) else { return false }
    return task.title == (redo ? entry.before : entry.after)
  }

  @discardableResult func perform(redo: Bool, store: WorkspaceStore, now: Date = Date()) -> String? {
    expire(now: now)
    guard canPerform(redo: redo, store: store, now: now),
      var entry = (redo ? redoEntries : undoEntries).last else { return nil }
    do {
      try store.persistTaskTitle(entry.taskID, title: redo ? entry.after : entry.before)
      entry.expiresAt = now.addingTimeInterval(60)
      if redo { redoEntries.removeLast(); undoEntries.append(entry) }
      else { undoEntries.removeLast(); redoEntries.append(entry) }
      failed = false
      message = redo ? "已重做任务重命名" : "任务名称已恢复"
      return entry.taskID
    } catch {
      failed = true
      message = (redo ? "无法重做重命名：" : "无法撤销重命名：") + error.localizedDescription
      return nil
    }
  }
}
