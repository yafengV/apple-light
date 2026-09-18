import Foundation

struct GitBranchChoice: Identifiable, Equatable, Sendable {
  let reference: String
  let commit: String
  let checkedOutPath: String?
  var id: String { reference }
  var isRemote: Bool { reference.hasPrefix("refs/remotes/") }
  var name: String { String(reference.dropFirst(isRemote ? "refs/remotes/".count : "refs/heads/".count)) }
  var suggestedLocalName: String {
    isRemote ? name.split(separator: "/").dropFirst().joined(separator: "/") : name
  }
}

struct GitBranchSnapshot: Equatable, Sendable {
  let root: URL
  let repositoryRoot: URL
  let currentReference: String?
  let currentCommit: String?
  let branches: [GitBranchChoice]
  let changedFiles: Int
  var canChange: Bool { root.path == repositoryRoot.path }
  var currentName: String {
    if let currentReference { return String(currentReference.dropFirst("refs/heads/".count)) }
    return "detached HEAD" + (currentCommit.map { " · " + $0.prefix(8) } ?? "")
  }
  func isOccupied(_ choice: GitBranchChoice) -> Bool {
    choice.checkedOutPath.map {
      GitBranchService.canonicalRoot(URL(fileURLWithPath: $0)).path != root.path
    } ?? false
  }
}

enum GitBranchChange {
  case switchTo(GitBranchChoice)
  case create(name: String, startingAt: GitBranchChoice?)
}
