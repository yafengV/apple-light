import CryptoKit
import Foundation
import SQLite3

/// Search reads persisted local runs without starting an Agent or changing its active runs.
enum TaskSearchHistory {
  struct Result { var runs: [AgentRun] = []; var errors: [String] = [] }

  static func database(root: URL, project: String) -> URL {
    let digest = SHA256.hash(data: Data(project.utf8)).map { String(format: "%02x", $0) }.joined()
    return root.appendingPathComponent("Projects/\(digest)/State/shipios.sqlite")
  }

  static func load(root: URL, library: WorkspaceLibrary) -> Result {
    var result = Result()
    let localIDs = Set(library.localRuns.map(\.id))
    let groups = Dictionary(
      grouping: library.tasks.filter { !$0.project.isEmpty && !$0.isPopoutDraft }, by: \.project)
    for (project, tasks) in groups.sorted(by: { $0.key < $1.key }) {
      if Task.isCancelled { break }
      let ids = Set(tasks.flatMap(\.runIDs)).subtracting(localIDs)
      guard !ids.isEmpty else { continue }
      let file = database(root: root, project: project)
      do {
        // A missing database still needs the same identity as its existing parent.
        // Foundation alone can retain /private/tmp for one and shorten the other.
        let boundary = GitBranchService.canonicalRoot(root).path + "/"
        guard GitBranchService.canonicalRoot(file).path.hasPrefix(boundary) else {
          throw AgentFailure(message: "历史记录路径不在当前数据目录内")
        }
        for path in [file.path, file.path + "-wal", file.path + "-shm"] {
          guard (try? FileManager.default.attributesOfItem(atPath: path)[.type]) as? FileAttributeType != .typeSymbolicLink else {
            throw AgentFailure(message: "历史记录文件已被符号链接替换")
          }
        }
        result.runs += try read(file).filter { $0.project == project && ids.contains($0.id) }
      } catch { result.errors.append("\(library.projectTitle(project))：\(error.localizedDescription)") }
    }
    return result
  }

  static func read(_ file: URL) throws -> [AgentRun] {
    var database: OpaquePointer?
    guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
      if let database { sqlite3_close(database) }
      throw AgentFailure(message: "无法读取本地任务历史")
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 500)
    var version: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &version, nil) == SQLITE_OK else {
      throw AgentFailure(message: "无法检查历史记录版本")
    }
    defer { sqlite3_finalize(version) }
    guard sqlite3_step(version) == SQLITE_ROW, sqlite3_column_int(version, 0) == 1 else {
      throw AgentFailure(message: "暂不支持此历史记录版本")
    }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "SELECT body FROM runs ORDER BY rowid DESC", -1, &statement, nil) == SQLITE_OK else {
      throw AgentFailure(message: "无法读取历史消息")
    }
    defer { sqlite3_finalize(statement) }
    var runs: [AgentRun] = []
    while true {
      try Task.checkCancellation()
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { return runs }
      guard status == SQLITE_ROW, let bytes = sqlite3_column_text(statement, 0) else {
        throw AgentFailure(message: "历史消息读取未完成，请重试")
      }
      let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
      runs.append(try JSONDecoder().decode(AgentRun.self, from: data))
    }
  }
}
