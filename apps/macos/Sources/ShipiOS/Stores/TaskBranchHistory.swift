import Foundation

extension WorkspaceStore {
  func branchForTaskHistory() async -> String? {
    guard let root = workspace.gitRoot ?? project,
      let result = try? await LocalWorkspaceService.git(["symbolic-ref", "--short", "-q", "HEAD"], at: root),
      result.status == 0 else { return nil }
    let name = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
  }
}
