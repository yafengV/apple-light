import Foundation

struct GitDiscardPlan: Identifiable {
  let id = UUID()
  let snapshot: GitBatchSnapshot
  let files: [GitFile]
  let restorePaths: [String]
  let trashPaths: [String]
  let intentPaths: [String]
  var message: String {
    let names = files.prefix(8).map { String(reflecting: $0.path) }.joined(separator: "\n")
    let more = files.count > 8 ? "\n另有 \(files.count - 8) 个文件" : ""
    return
      "涉及 \(files.count) 个文件：\n\(names)\(more)\n\n恢复 \(restorePaths.count) 个已跟踪路径至暂存区版本；\(trashPaths.count) 个新增文件移入废纸篓。已暂存内容保留，已跟踪文件的未暂存修改会丢失。"
  }
}

enum GitDiscardService {
  static func prepare(_ expected: GitBatchSnapshot, selectedPath: String? = nil) async throws
    -> GitDiscardPlan
  {
    guard expected.scope == .unstaged else { throw AgentFailure(message: "此操作仅用于未暂存修改。") }
    let current = try await verified(expected)
    let files = current.selectedFiles.filter { selectedPath == nil || $0.path == selectedPath }
    guard !files.isEmpty else { throw AgentFailure(message: "没有可撤销的未暂存变更。请刷新。") }
    guard !files.contains(where: \.conflicted) else {
      throw AgentFailure(message: "包含尚未解决的合并冲突，请先处理冲突再撤销。")
    }
    let allPaths = Array(Set(files.flatMap { $0.comparisonPaths(scope: .unstaged) })).sorted()
    var indexModes: [String: String] = [:]
    for start in stride(from: 0, to: allPaths.count, by: 32) {
      let paths = Array(allPaths[start..<min(start + 32, allPaths.count)])
      let entries = try await GitReviewService.checked(
        ["ls-files", "--stage", "-z", "--"] + paths, at: current.root)
      for entry in entries.split(separator: "\0") {
        let pieces = entry.split(separator: "\t", maxSplits: 1)
        if pieces.count == 2 { indexModes[String(pieces[1])] = String(pieces[0].prefix(6)) }
      }
    }
    for path in allPaths {
      let file = try GitBatchService.gitPath(path, root: current.root)
      let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
      guard indexModes[path] != "160000", attributes?[.type] as? FileAttributeType != .typeDirectory
      else {
        throw AgentFailure(message: "\(path) 是子仓库或文件夹。请在相应项目内处理，当前未执行撤销。")
      }
    }
    var restore: [String] = []
    var trash: [String] = []
    var intent: [String] = []
    for file in files {
      if file.untracked || file.intentToAdd {
        trash.append(file.path)
        if file.intentToAdd { intent.append(file.path) }
      } else if file.worktreeRename, let old = file.originalPath {
        restore.append(old)
        trash.append(file.path)
      } else {
        restore.append(file.path)
      }
    }
    return GitDiscardPlan(
      snapshot: current, files: files, restorePaths: restore,
      trashPaths: trash, intentPaths: intent)
  }

  static func execute(_ plan: GitDiscardPlan, trash: (URL) throws -> Void = moveToTrash)
    async throws
  {
    guard plan.snapshot.scope == .unstaged else { throw AgentFailure(message: "此操作仅用于未暂存修改。") }
    let current = try await verified(plan.snapshot)
    let allowed = Set(plan.files.flatMap { $0.comparisonPaths(scope: .unstaged) })
    guard plan.files.allSatisfy({ current.selectedFiles.contains($0) }),
      Set(plan.restorePaths + plan.trashPaths + plan.intentPaths).isSubset(of: allowed)
    else {
      throw AgentFailure(message: "撤销范围无效，请刷新并重新确认。")
    }
    var moved = 0
    var restoreStarted = false
    do {
      for path in plan.trashPaths {
        let file = try GitBatchService.gitPath(path, root: plan.snapshot.root)
        try trash(file)
        moved += 1
      }
      if !plan.restorePaths.isEmpty {
        restoreStarted = true
        try await GitBatchService.runPathCommand(
          ["restore", "--worktree"], paths: plan.restorePaths, at: plan.snapshot.root)
      }
      try await GitBatchService.runPathCommand(
        ["rm", "--cached", "--force", "--ignore-unmatch"], paths: plan.intentPaths,
        at: plan.snapshot.root)
    } catch {
      let progress =
        moved > 0 || restoreStarted
        ? "部分操作可能已完成，已移入废纸篓 \(moved) 项。请检查刷新后的状态。\n" : "尚未完成撤销。\n"
      throw AgentFailure(message: progress + error.localizedDescription)
    }
  }

  private static func verified(_ expected: GitBatchSnapshot) async throws -> GitBatchSnapshot {
    let current = try await GitBatchService.capture(scope: expected.scope, at: expected.root)
    guard current.signature == expected.signature, current.paths == expected.paths else {
      throw AgentFailure(message: "文件或索引已改变，未执行撤销。请刷新并重新确认。")
    }
    return current
  }
  static func moveToTrash(_ file: URL) throws {
    try FileManager.default.trashItem(at: file, resultingItemURL: nil)
  }
}
