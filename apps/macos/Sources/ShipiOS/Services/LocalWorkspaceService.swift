import Foundation

struct CommandOutput: Sendable {
  let status: Int32
  let text: String
}

/// No shell interpolation. Output is drained into a temporary file to avoid pipe deadlocks.
enum LocalWorkspaceService {
  static func command(_ executable: String, _ arguments: [String], at root: URL,
    indexFile: URL? = nil, cancelWithTask: Bool = false) async throws
    -> CommandOutput
  {
    let job = Task.detached(priority: .userInitiated) {
      try runCommand(executable, arguments, at: root, indexFile: indexFile)
    }
    return try await withTaskCancellationHandler {
      try await job.value
    } onCancel: {
      if cancelWithTask { job.cancel() }
    }
  }
  private static func runCommand(_ executable: String, _ arguments: [String], at root: URL,
    indexFile: URL?) throws
    -> CommandOutput
  {
    try Task<Never, Never>.checkCancellation()
    let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    FileManager.default.createFile(
      atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
    defer { try? FileManager.default.removeItem(at: output) }
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close() }
    let errorURL = output.appendingPathExtension("stderr")
    FileManager.default.createFile(
      atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
    defer { try? FileManager.default.removeItem(at: errorURL) }
    let errorHandle = try FileHandle(forWritingTo: errorURL)
    defer { try? errorHandle.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = root
    process.environment = [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8",
      "GIT_TERMINAL_PROMPT": "0",
      "GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "GH_PAGER": "cat",
      "GIT_CEILING_DIRECTORIES": root.resolvingSymlinksInPath().deletingLastPathComponent().path,
    ]
    if let indexFile { process.environment?["GIT_INDEX_FILE"] = indexFile.path }
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = handle
    process.standardError = errorHandle
    try process.run()
    let deadline = Date().addingTimeInterval(20)
    while process.isRunning && Date() < deadline && !Task<Never, Never>.isCancelled { Thread.sleep(forTimeInterval: 0.03) }
    if process.isRunning {
      process.terminate()
      Thread.sleep(forTimeInterval: 0.1)
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
      try Task<Never, Never>.checkCancellation()
      throw AgentFailure(message: "命令超时，请在终端检查项目。")
    }
    process.waitUntilExit()
    try Task<Never, Never>.checkCancellation()
    let reader = try FileHandle(forReadingFrom: output)
    defer { try? reader.close() }
    let data = try reader.read(upToCount: 1_048_577) ?? Data()
    guard data.count <= 1_048_576 else {
      throw AgentFailure(message: "Output exceeds 1 MiB; inspect this repository in the terminal.")
    }
    var text = String(decoding: data, as: UTF8.self)
    if process.terminationStatus != 0 {
      let errors = try FileHandle(forReadingFrom: errorURL)
      defer { try? errors.close() }
      text += String(decoding: try errors.read(upToCount: 262_144) ?? Data(), as: UTF8.self)
    }
    return CommandOutput(status: process.terminationStatus, text: text)
  }
  static func git(_ arguments: [String], at root: URL, indexFile: URL? = nil) async throws -> CommandOutput {
    try await command(
      "/usr/bin/git",
      [
        "--no-pager", "--literal-pathspecs", "-c", "color.ui=false", "-c",
        "status.relativePaths=true", "-c", "core.fsmonitor=false",
      ] + arguments, at: root, indexFile: indexFile)
  }
  static func resolvedFile(_ path: String, root: URL) throws -> URL {
    let base = root.resolvingSymlinksInPath().standardizedFileURL
    let file = base.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
    guard file.path.hasPrefix(base.path + "/") else { throw AgentFailure(message: "文件不在项目目录内。") }
    return file
  }
  static func read(_ path: String, root: URL) throws -> String {
    let file = try resolvedFile(path, root: root)
    let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true, (values.fileSize ?? 0) <= 1_048_576 else {
      throw AgentFailure(message: "仅预览 1 MiB 以内的普通文本文件，请在外部应用打开。")
    }
    let data = try Data(contentsOf: file)
    guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
      throw AgentFailure(message: "这是二进制文件或不支持的编码，请在外部应用打开。")
    }
    return text
  }
  static func files(at root: URL) async throws -> [String] {
    let root = root.resolvingSymlinksInPath().standardizedFileURL
    let git = try await git(
      ["ls-files", "--cached", "--others", "--exclude-standard", "-z"], at: root)
    if git.status == 0, !git.text.isEmpty {
      return Array(Set(git.text.split(separator: "\0").map(String.init))).sorted()
    }
    return await Task.detached { enumerateFiles(at: root) }.value
  }
  private static func enumerateFiles(at root: URL) -> [String] {
    let excluded: Set<String> = [
      ".git", ".cache", ".build", "node_modules", "target", "dist", "DerivedData",
    ]
    guard
      let iterator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles])
    else { return [String]() }
    var paths: [String] = []
    var visited = 0
    for case let url as URL in iterator {
      visited += 1
      if visited > 20_000 { break }
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      if excluded.contains(url.lastPathComponent) || values?.isSymbolicLink == true {
        iterator.skipDescendants()
        continue
      }
      if values?.isDirectory != true {
        paths.append(
          String(
            url.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(root.path.count + 1)))
      }
    }
    return paths.sorted()
  }
}

struct GitFile: Identifiable, Equatable {
  let path: String
  let staged: Bool
  let unstaged: Bool
  let untracked: Bool
  var originalPath: String? = nil
  var indexRename = false
  var worktreeRename = false
  var intentToAdd = false
  var conflicted = false
  var displayPath: String { originalPath.map { $0 + " → " + path } ?? path }
  func comparisonPaths(scope: GitReviewScope) -> [String] {
    if let originalPath,
      scope.isHistorical || (scope == .staged && indexRename)
        || (scope == .unstaged && worktreeRename)
    {
      return [originalPath, path]
    }
    return [path]
  }
  var id: String { path }
  static func parse(_ text: String) -> [Self] {
    let parts = text.split(separator: "\0", omittingEmptySubsequences: true)
    var result: [Self] = []
    var i = 0
    while i < parts.count {
      let entry = String(parts[i])
      i += 1
      guard entry.count >= 4 else { continue }
      let x = entry.first!
      let y = entry.dropFirst().first!
      let hasSource = x == "R" || x == "C" || y == "R" || y == "C"
      let source = hasSource && i < parts.count ? String(parts[i]) : nil
      result.append(
        Self(
          path: String(entry.dropFirst(3)), staged: x != " " && x != "?",
          unstaged: y != " " || x == "?", untracked: x == "?", originalPath: source,
          indexRename: x == "R", worktreeRename: y == "R", intentToAdd: x == " " && y == "A",
          conflicted: x == "U" || y == "U" || (x == y && (x == "A" || x == "D"))))
      if hasSource { i += 1 }
    }
    return result
  }
  static func parseNameStatus(_ text: String) -> [Self] {
    let fields = text.split(separator: "\0").map(String.init)
    var files: [Self] = []
    var index = 0
    while index + 1 < fields.count {
      let status = fields[index]
      let first = fields[index + 1]
      index += 2
      if status.hasPrefix("R") || status.hasPrefix("C") {
        guard index < fields.count else { break }
        files.append(
          Self(
            path: fields[index], staged: false, unstaged: false, untracked: false,
            originalPath: first))
        index += 1
      } else {
        files.append(Self(path: first, staged: false, unstaged: false, untracked: false))
      }
    }
    return files
  }
}
