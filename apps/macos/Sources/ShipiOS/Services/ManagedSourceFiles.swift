import CryptoKit
import Darwin
import Foundation

/// Snapshot files before creating a checkout so retries never read a changed source file.
enum ManagedSourceFiles {
  private static let folder = "ManagedSourceSnapshots"

  static func discover(at source: URL, excluding dataRoot: URL? = nil) async throws -> [String] {
    let ordinary = try await GitReviewService.checked(
      ["ls-files", "--others", "--exclude-standard", "-z"], at: source)
    var paths = Set(split(ordinary))
    let ignored = Set(split(try await GitReviewService.checked(
      ["ls-files", "--others", "--ignored", "--exclude-standard", "-z"], at: source)))
    let include = source.appendingPathComponent(".worktreeinclude")
    if type(at: include) != nil {
      guard type(at: include) == mode_t(S_IFREG) else {
        throw AgentFailure(message: ".worktreeinclude 必须是普通文件。")
      }
      let requested = Set(split(try await GitReviewService.checked(
        ["ls-files", "--others", "--ignored", "--exclude-from=.worktreeinclude", "-z"],
        at: source)))
      paths.formUnion(ignored.intersection(requested).filter {
        type(at: source.appendingPathComponent($0)) != mode_t(S_IFLNK)
      })
    }
    paths.formUnion(ignored.filter {
      URL(fileURLWithPath: $0).lastPathComponent == "AGENTS.override.md"
        && type(at: source.appendingPathComponent($0)) != mode_t(S_IFLNK)
    })
    return try withoutPrivateData(paths, source: source, dataRoot: dataRoot).sorted()
  }

  /// Archiving removes the checkout, so even ignored files must be accounted for.
  static func discoverAll(at source: URL, excluding dataRoot: URL? = nil) async throws -> [String] {
    let ordinary = Set(split(try await GitReviewService.checked(
      ["ls-files", "--others", "--exclude-standard", "-z"], at: source)))
    let ignored = Set(split(try await GitReviewService.checked(
      ["ls-files", "--others", "--ignored", "--exclude-standard", "-z"], at: source)))
    return try withoutPrivateData(ordinary.union(ignored), source: source,
      dataRoot: dataRoot).sorted()
  }

  static func archiveSnapshotMatches(_ files: [ManagedSourceFile], source: URL,
    dataRoot: URL, taskID: String) async throws -> Bool {
    guard try await discoverAll(at: source, excluding: dataRoot) == files.map(\.path).sorted() else {
      return false
    }
    let savedRoot = directory(dataRoot: dataRoot, taskID: taskID)
    for entry in files {
      let parts = try components(entry.path)
      let current = try regularFile(root: source, parts: parts)
      let saved = try regularFile(root: savedRoot, parts: parts)
      let currentHash = try hash(current)
      let savedHash = try hash(saved)
      guard currentHash == entry.sha256, savedHash == entry.sha256 else { return false }
      let currentAttributes = try FileManager.default.attributesOfItem(atPath: current.path)
      let savedAttributes = try FileManager.default.attributesOfItem(atPath: saved.path)
      guard (currentAttributes[.posixPermissions] as? NSNumber)?.intValue == entry.permissions,
        (savedAttributes[.posixPermissions] as? NSNumber)?.intValue == entry.permissions else {
        return false
      }
    }
    return true
  }

  static func capture(_ paths: [String], from source: URL, dataRoot: URL,
    taskID: String) throws -> [ManagedSourceFile] {
    guard UUID(uuidString: taskID) != nil else {
      throw AgentFailure(message: "工作树任务 ID 无效。")
    }
    guard !paths.isEmpty else { return [] }
    let parent = dataRoot.appendingPathComponent(folder, isDirectory: true)
    if let existing = type(at: parent), existing != mode_t(S_IFDIR) {
      throw AgentFailure(message: "私有工作树快照目录无效。")
    }
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
    guard type(at: parent) == mode_t(S_IFDIR) else {
      throw AgentFailure(message: "私有工作树快照目录无效。")
    }
    let staging = parent.appendingPathComponent(taskID + ".pending-" + UUID().uuidString,
      isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: staging) }
    var entries: [ManagedSourceFile] = []
    for path in paths {
      let parts = try components(path)
      let origin = try regularFile(root: source, parts: parts)
      let destination = try destination(root: staging, parts: parts)
      try FileManager.default.copyItem(at: origin, to: destination)
      let sourceHash = try hash(origin)
      let snapshotHash = try hash(destination)
      guard sourceHash == snapshotHash else {
        throw AgentFailure(message: "来源文件在创建工作树快照时发生变化：\(path)")
      }
      let attributes = try FileManager.default.attributesOfItem(atPath: origin.path)
      let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
      entries.append(.init(path: path, sha256: snapshotHash, permissions: permissions))
    }
    let final = directory(dataRoot: dataRoot, taskID: taskID)
    if let existing = type(at: final) {
      guard existing == mode_t(S_IFDIR) else {
        throw AgentFailure(message: "私有工作树快照位置已被占用。")
      }
      try FileManager.default.removeItem(at: final)
    }
    try FileManager.default.moveItem(at: staging, to: final)
    return entries
  }

  static func install(_ files: [ManagedSourceFile], dataRoot: URL,
    taskID: String, target: URL) throws {
    guard UUID(uuidString: taskID) != nil else {
      throw AgentFailure(message: "工作树任务 ID 无效。")
    }
    guard !files.isEmpty else { return }
    guard type(at: dataRoot.appendingPathComponent(folder, isDirectory: true)) == mode_t(S_IFDIR) else {
      throw AgentFailure(message: "私有工作树快照目录无效。")
    }
    let root = directory(dataRoot: dataRoot, taskID: taskID)
    guard type(at: root) == mode_t(S_IFDIR) else {
      throw AgentFailure(message: "工作树文件快照缺失，无法恢复：\(root.path)")
    }
    for entry in files {
      let parts = try components(entry.path)
      let saved = try regularFile(root: root, parts: parts)
      guard try hash(saved) == entry.sha256 else {
        throw AgentFailure(message: "工作树文件快照已改变：\(entry.path)")
      }
      let savedAttributes = try FileManager.default.attributesOfItem(atPath: saved.path)
      guard (savedAttributes[.posixPermissions] as? NSNumber)?.intValue == entry.permissions else {
        throw AgentFailure(message: "工作树文件快照权限已改变：\(entry.path)")
      }
      let output = try destination(root: target, parts: parts)
      if let existing = type(at: output) {
        guard existing == mode_t(S_IFREG), try hash(output) == entry.sha256 else {
          throw AgentFailure(message: "工作树已有不同内容，未覆盖：\(entry.path)")
        }
      } else {
        try FileManager.default.copyItem(at: saved, to: output)
      }
      guard try hash(output) == entry.sha256 else {
        throw AgentFailure(message: "工作树文件复制后校验失败：\(entry.path)")
      }
      let outputAttributes = try FileManager.default.attributesOfItem(atPath: output.path)
      guard (outputAttributes[.posixPermissions] as? NSNumber)?.intValue == entry.permissions else {
        throw AgentFailure(message: "工作树文件权限与来源不一致：\(entry.path)")
      }
    }
  }

  static func removeSnapshot(dataRoot: URL, taskID: String) {
    guard UUID(uuidString: taskID) != nil else { return }
    guard type(at: dataRoot.appendingPathComponent(folder, isDirectory: true)) == mode_t(S_IFDIR) else { return }
    let root = directory(dataRoot: dataRoot, taskID: taskID)
    if type(at: root) == mode_t(S_IFDIR) { try? FileManager.default.removeItem(at: root) }
  }

  private static func directory(dataRoot: URL, taskID: String) -> URL {
    dataRoot.appendingPathComponent(folder, isDirectory: true)
      .appendingPathComponent(taskID, isDirectory: true)
  }

  private static func split(_ output: String) -> [String] {
    output.split(separator: "\0").map(String.init)
  }

  private static func withoutPrivateData(_ paths: Set<String>, source: URL,
    dataRoot: URL?) throws -> Set<String> {
    guard let dataRoot else { return paths }
    let sourcePath = GitBranchService.canonicalRoot(source).path
    let privatePath = GitBranchService.canonicalRoot(dataRoot).path
    guard sourcePath != privatePath else {
      throw AgentFailure(message: "ShipiOS 数据目录不能与项目根目录相同。")
    }
    guard privatePath.hasPrefix(sourcePath + "/") else { return paths }
    let relative = String(privatePath.dropFirst(sourcePath.count + 1))
    return paths.filter { $0 != relative && !$0.hasPrefix(relative + "/") }
  }

  private static func components(_ path: String) throws -> [String] {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0 != ".git" }),
      !path.hasPrefix("/") else {
      throw AgentFailure(message: "工作树文件路径无效：\(path)")
    }
    return parts
  }

  private static func regularFile(root: URL, parts: [String]) throws -> URL {
    var current = root
    for (index, part) in parts.enumerated() {
      current.appendPathComponent(part)
      guard type(at: current) == (index == parts.count - 1 ? mode_t(S_IFREG) : mode_t(S_IFDIR)) else {
        throw AgentFailure(message: "工作树源文件必须是普通文件，且路径不能包含符号链接：\(parts.joined(separator: "/"))")
      }
    }
    return current
  }

  private static func destination(root: URL, parts: [String]) throws -> URL {
    var current = root
    for part in parts.dropLast() {
      current.appendPathComponent(part, isDirectory: true)
      if let existing = type(at: current) {
        guard existing == mode_t(S_IFDIR) else {
          throw AgentFailure(message: "工作树目标路径包含非目录：\(parts.joined(separator: "/"))")
        }
      } else {
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
      }
    }
    return current.appendingPathComponent(parts.last!)
  }

  private static func hash(_ file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func type(at url: URL) -> mode_t? {
    var info = stat()
    let result = url.withUnsafeFileSystemRepresentation { name in
      name.map { Darwin.lstat($0, &info) } ?? -1
    }
    return result == 0 ? info.st_mode & mode_t(S_IFMT) : nil
  }
}
