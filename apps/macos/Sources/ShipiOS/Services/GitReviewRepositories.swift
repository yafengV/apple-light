import Foundation

struct GitReviewRepositoryDiscovery {
  var repositories: [GitReviewRepository] = []
  var folderErrors: [String: String] = [:]
}

enum GitReviewRepositories {
  static func discover(_ folders: [URL]) async -> GitReviewRepositoryDiscovery {
    var result = GitReviewRepositoryDiscovery(), seen = Set<String>()
    for (index, folder) in folders.enumerated() {
      do {
        guard let candidate = try GitRepositoryContext.candidate(at: folder) else { continue }
        guard seen.insert(candidate.path).inserted else { continue }
        var repository = GitReviewRepository(root: candidate, folder: folder, isPrimary: index == 0)
        do { _ = try await GitRepositoryContext.resolve(at: folder) }
        catch { repository.readError = error.localizedDescription }
        result.repositories.append(repository)
      } catch { result.folderErrors[folder.path] = error.localizedDescription }
      if Task.isCancelled { break }
    }
    return result
  }
}
