import Foundation

struct ManagedSourceFile: Codable, Equatable {
  let path: String
  let sha256: String
  let permissions: Int
}

enum HandoffDirection: String, Codable {
  case toWorktree, toLocal
}

enum HandoffPhase: String, Codable {
  case applying, clearing, finalizing, releasing
}

struct PendingHandoff: Codable, Equatable {
  let direction: HandoffDirection
  let snapshot: HandoffGitSnapshot
  var phase: HandoffPhase
}

/// A checkout reserved for one task, separate from a permanent worktree project.
struct ManagedWorktree: Codable, Identifiable, Equatable {
  let taskID: String
  var checkout: PermanentWorktree
  /// A protected Git stash commit captured without changing the source checkout.
  var sourceStashCommit: String? = nil
  var sourceCopiedFiles: [ManagedSourceFile]? = nil
  var sourceChangesApplied: Bool? = nil
  /// A successful setup is durable so retries never repeat a completed script.
  var setupCompleted: Bool? = nil
  /// Set after a configured cleanup script succeeds, before taking the archive snapshot.
  var cleanupCompleted: Bool? = nil
  /// Reserved before switching the local checkout during Worktree → Local handoff.
  var handoffBranch: String? = nil
  /// Persisted before touching the target; retained until both checkouts and the task move agree.
  var pendingHandoff: PendingHandoff? = nil
  /// Protected by refs/shipios/managed-archive/<taskID> until this checkout is restored.
  var archivedHead: String? = nil
  var archivedStashCommit: String? = nil
  var archivedCopiedFiles: [ManagedSourceFile]? = nil
  var archivedPruned: Bool? = nil

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
