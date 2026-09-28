import Foundation

extension WorkspaceStore {
  func branchForTaskHistory() async -> String? {
    guard let project, let root = try? await GitRepositoryContext.resolve(at: project),
      let result = try? await LocalWorkspaceService.git(["symbolic-ref", "--short", "-q", "HEAD"], at: root),
      result.status == 0, self.project == project else { return nil }
    let name = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
  }
}
