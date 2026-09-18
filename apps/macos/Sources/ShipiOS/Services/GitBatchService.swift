import CryptoKit
import Foundation

struct GitBatchSnapshot {
  let root: URL
  let scope: GitReviewScope
  let files: [GitFile]
  let paths: [String]
  let head: String?
  let signature: String
  var selectedFiles: [GitFile] { files.filter { scope == .staged ? $0.staged : $0.unstaged } }
}

enum GitBatchService {
  private static let statusArgs = [
    "status", "--porcelain=v1", "-z", "--untracked-files=all", "--", ".",
  ]
  private static let indexArgs = [
    "diff", "--cached", "--raw", "--no-ext-diff", "--no-textconv", "--abbrev=64", "-z", "--", ".",
  ]

  static func capture(scope: GitReviewScope, at root: URL) async throws -> GitBatchSnapshot {
    guard !scope.isHistorical else { throw AgentFailure(message: "历史范围不能批量修改。") }
    let status = try await GitReviewService.checked(statusArgs, at: root)
    let index = try await GitReviewService.checked(indexArgs, at: root)
    let head = try await head(at: root)
    let files = GitFile.parse(status)
    let selected = files.filter { scope == .staged ? $0.staged : $0.unstaged }
    let paths = Array(Set(selected.flatMap { $0.comparisonPaths(scope: scope) })).sorted()
    var state = [scope.rawValue, status, index, head ?? "unborn"]
    for path in paths {
      let file = try gitPath(path, root: root)
      if scope == .unstaged {
        let attributes = try await Task.detached { try workingState(file) }.value
        if attributes == "directory" {
          let nestedHead = try await GitReviewService.checked(
            ["rev-parse", "--verify", "HEAD"], at: file)
          state += [path, "gitlink:" + nestedHead]
        } else {
          state += [path, attributes]
        }
      }
    }
    guard try await GitReviewService.checked(statusArgs, at: root) == status,
      try await GitReviewService.checked(indexArgs, at: root) == index,
      try await self.head(at: root) == head
    else {
      throw AgentFailure(message: "仓库正在变化，请稍后刷新变更。")
    }
    let data = try JSONEncoder().encode(state)
    return GitBatchSnapshot(
      root: root, scope: scope, files: files, paths: paths, head: head,
      signature: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
  }

  static func apply(_ snapshot: GitBatchSnapshot) async throws {
    guard !snapshot.paths.isEmpty else { return }
    let current = try await capture(scope: snapshot.scope, at: snapshot.root)
    guard current.signature == snapshot.signature, current.paths == snapshot.paths else {
      throw AgentFailure(message: "文件或索引已改变，未执行批量操作。请刷新后重试。")
    }
    let command: [String]
    if snapshot.scope == .unstaged {
      command = ["add", "--all"]
    } else if let head = snapshot.head {
      command = ["restore", "--staged", "--source=" + head]
    } else {
      // Removing index entries is also safe when an unborn branch's working files differ.
      command = ["rm", "--cached", "--force", "--ignore-unmatch"]
    }
    try await runPathCommand(command, paths: snapshot.paths, at: snapshot.root)
  }

  static func runPathCommand(_ command: [String], paths: [String], at root: URL) async throws {
    guard !paths.isEmpty else { return }
    for path in paths { _ = try gitPath(path, root: root) }
    let manifest = FileManager.default.temporaryDirectory.appendingPathComponent(
      "shipios-paths-" + UUID().uuidString)
    let data = Data((paths.joined(separator: "\0") + "\0").utf8)
    guard
      FileManager.default.createFile(
        atPath: manifest.path, contents: data, attributes: [.posixPermissions: 0o600])
    else {
      throw AgentFailure(message: "无法准备文件列表。")
    }
    defer { try? FileManager.default.removeItem(at: manifest) }
    _ = try await GitReviewService.checked(
      command + ["--pathspec-from-file=" + manifest.path, "--pathspec-file-nul"], at: root)
  }

  private static func head(at root: URL) async throws -> String? {
    let result = try await LocalWorkspaceService.git(["rev-parse", "--verify", "HEAD"], at: root)
    return result.status == 0 ? result.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
  }

  /// Validate parents, but do not follow the final symlink: Git stages the link itself.
  static func gitPath(_ path: String, root: URL) throws -> URL {
    guard !path.hasPrefix("/"),
      !path.split(separator: "/").contains(where: { $0 == ".." || $0.lowercased() == ".git" })
    else {
      throw AgentFailure(message: "Git 路径不在项目范围内。")
    }
    let base = root.resolvingSymlinksInPath().standardizedFileURL
    let file = base.appendingPathComponent(path).standardizedFileURL
    let parent = file.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
    guard file.path.hasPrefix(base.path + "/"),
      parent.path == base.path || parent.path.hasPrefix(base.path + "/")
    else {
      throw AgentFailure(message: "Git 路径不在项目范围内。")
    }
    return file
  }

  private static func workingState(_ file: URL) throws -> String {
    let attributes: [FileAttributeKey: Any]
    do { attributes = try FileManager.default.attributesOfItem(atPath: file.path) } catch let error
      as NSError
      where error.domain == NSCocoaErrorDomain
      && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
    { return "missing" }
    let type = attributes[.type] as? FileAttributeType
    if type == .typeSymbolicLink {
      return "link:" + (try FileManager.default.destinationOfSymbolicLink(atPath: file.path))
    }
    if type == .typeDirectory { return "directory" }
    guard type == .typeRegular else {
      throw AgentFailure(message: "批量操作不支持此文件类型：\(file.lastPathComponent)")
    }
    let reader = try FileHandle(forReadingFrom: file)
    defer { try? reader.close() }
    var hash = SHA256()
    while let chunk = try reader.read(upToCount: 1_048_576), !chunk.isEmpty {
      hash.update(data: chunk)
    }
    return "file:\(attributes[.posixPermissions] ?? 0):"
      + hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
