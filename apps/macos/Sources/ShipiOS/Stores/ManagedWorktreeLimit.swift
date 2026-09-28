import Foundation

extension WorkspaceStore {
  var managedWorktreeCount: Int {
    library.managedWorktrees.filter {
      $0.ready && $0.archivedPruned != true
        && FileManager.default.fileExists(atPath: $0.path)
    }.count
  }

  func setAutomaticManagedWorktreeDeletion(_ enabled: Bool) {
    guard libraryLoaded else { return }
    do {
      var candidate = library
      candidate.automaticallyDeleteManagedWorktrees = enabled
      try commitLibrary(candidate)
      worktreeError = nil
      if enabled { scheduleManagedLimitCleanup() }
    } catch { worktreeError = error.localizedDescription }
  }

  func setManagedWorktreeLimit(_ value: Int) {
    guard libraryLoaded else { return }
    do {
      var candidate = library
      candidate.managedWorktreeLimit = max(1, value)
      try commitLibrary(candidate)
      worktreeError = nil
      if candidate.automaticallyDeleteManagedWorktrees { scheduleManagedLimitCleanup() }
    } catch { worktreeError = error.localizedDescription }
  }

  func scheduleManagedLimitCleanup() {
    guard !managedTaskPreparing, library.automaticallyDeleteManagedWorktrees,
      managedWorktreeCount > library.managedWorktreeLimit else { return }
    let previous = managedLimitCleanupTask
    managedLimitCleanupTask = Task { @MainActor in
      await previous?.value
      await managedArchiveCleanupTask?.value
      await cleanupOldManagedWorktrees()
    }
  }

  func cleanupOldManagedWorktrees() async {
    guard library.automaticallyDeleteManagedWorktrees else { return }
    let oldest = library.managedWorktrees.filter {
      $0.ready && $0.archivedPruned != true
        && FileManager.default.fileExists(atPath: $0.path)
    }.sorted { lhs, rhs in
      let left = max(library.managedTasks(for: lhs).compactMap(\.updatedAt).max()
        ?? lhs.checkout.createdAt, lhs.checkout.createdAt)
      let right = max(library.managedTasks(for: rhs).compactMap(\.updatedAt).max()
        ?? rhs.checkout.createdAt, rhs.checkout.createdAt)
      return left == right ? lhs.taskID < rhs.taskID : left < right
    }
    for record in oldest {
      guard library.automaticallyDeleteManagedWorktrees,
        managedWorktreeCount > library.managedWorktreeLimit else { break }
      if let member = library.managedTasks(for: record).first {
        await pruneManagedWorktreeIfEligible(member.id, dueToLimit: true)
      }
    }
  }
}
