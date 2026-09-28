import Foundation

struct ActivityArchiveRequest: Identifiable {
  let id = UUID()
  let taskIDs: [String]
}

struct ActivityArchiveResult: Equatable {
  var archivedIDs: [String] = []
  var failures: [String: String] = [:]
  var message: String {
    failures.isEmpty ? "已归档 \(archivedIDs.count) 个优先任务"
      : "已归档 \(archivedIDs.count) 个优先任务；\(failures.count) 个无法归档"
  }
}
