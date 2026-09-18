import Foundation

extension WorkspaceStore {
  func branchForTaskHistory() async -> String? {
    guard let project,
      let result = try? await LocalWorkspaceService.git(["symbolic-ref", "--short", "-q", "HEAD"], at: project),
      result.status == 0 else { return nil }
    let name = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
  }
}
