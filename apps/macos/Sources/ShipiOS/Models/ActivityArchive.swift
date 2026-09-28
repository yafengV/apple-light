import Foundation

struct ActivityArchiveRequest: Identifiable {
  enum Scope { case priority, task }
  let id = UUID()
  let taskIDs: [String]
  var scope: Scope = .priority
}

struct ActivityArchiveResult: Equatable {
  var archivedIDs: [String] = []
  var failures: [String: String] = [:]
  var message: String {
    failures.isEmpty ? "已归档 \(archivedIDs.count) 个任务"
      : "已归档 \(archivedIDs.count) 个任务；\(failures.count) 个无法归档"
  }
}
