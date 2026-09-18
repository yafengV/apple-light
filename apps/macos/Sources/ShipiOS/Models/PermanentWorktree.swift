import Foundation

/// Persisted before checkout so interrupted creation can be recovered without losing its path.
struct PermanentWorktree: Codable, Identifiable, Equatable {
  let id: UUID
  let source: String
  let path: String
  let commonDirectory: String
  let startingCommit: String
  let startingName: String
  let createdAt: Date
  let title: String
  var ready = false
}
