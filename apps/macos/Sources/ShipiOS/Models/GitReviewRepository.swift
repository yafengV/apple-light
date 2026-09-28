import Foundation

struct GitReviewRepository: Identifiable, Equatable {
  let root: URL
  let folder: URL
  let isPrimary: Bool
  var readError: String?
  var id: String { root.path }
  var title: String { root.lastPathComponent }
}

struct GitReviewRepositoryDraft {
  var message: String
  var commit: String
  var branch: String
  var collapsed: Set<String>
}
