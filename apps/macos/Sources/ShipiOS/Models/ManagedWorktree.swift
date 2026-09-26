import Foundation

struct ManagedSourceFile: Codable, Equatable {
  let path: String
  let sha256: String
  let permissions: Int
}

/// A checkout reserved for one task, separate from a permanent worktree project.
struct ManagedWorktree: Codable, Identifiable, Equatable {
  let taskID: String
  var checkout: PermanentWorktree
  /// A protected Git stash commit captured without changing the source checkout.
  var sourceStashCommit: String? = nil
  var sourceCopiedFiles: [ManagedSourceFile]? = nil
  var sourceChangesApplied: Bool? = nil

  var id: UUID { checkout.id }
  var source: String { checkout.source }
  var path: String { checkout.path }
  var ready: Bool { checkout.ready }
}

enum NewTaskExecution: String, Codable, CaseIterable, Identifiable {
  case local, worktree

  var id: String { rawValue }
  var title: String { self == .local ? "本地" : "工作树" }
}
