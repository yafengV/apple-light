import Foundation

enum LocalEnvironmentScriptService {
  enum Phase { case setup, cleanup
    var label: String { self == .setup ? "初始化" : "清理" }
  }

  static func run(_ script: String, phase: Phase, source: URL, worktree: URL) async throws {
    let task = Task.detached(priority: .userInitiated) {
      try runProcess(script, phase: phase, source: source, worktree: worktree)
    }
    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private static func runProcess(_ script: String, phase: Phase, source: URL,
    worktree: URL) throws {
    try Task<Never, Never>.checkCancellation()
    let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    guard FileManager.default.createFile(atPath: output.path, contents: nil,
      attributes: [.posixPermissions: 0o600]) else {
      throw AgentFailure(message: "无法创建工作树\(phase.label)日志。")
    }
    defer { try? FileManager.default.removeItem(at: output) }
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-l", "-c", script]
    process.currentDirectoryURL = phase == .setup ? worktree : source
    var environment = ProcessInfo.processInfo.environment
    environment["CODEX_SOURCE_TREE_PATH"] = source.path
    environment["CODEX_WORKTREE_PATH"] = worktree.path
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = handle
    process.standardError = handle
    try process.run()
    let deadline = Date().addingTimeInterval(600)
    while process.isRunning && Date() < deadline && !Task<Never, Never>.isCancelled {
      Thread.sleep(forTimeInterval: 0.1)
    }
    let timedOut = Date() >= deadline
    if process.isRunning {
      process.terminate()
      Thread.sleep(forTimeInterval: 0.1)
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    process.waitUntilExit()
    try Task<Never, Never>.checkCancellation()
    if timedOut { throw AgentFailure(message: "工作树\(phase.label)超过 10 分钟，请检查脚本。") }
    guard process.terminationStatus == 0 else {
      let reader = try FileHandle(forReadingFrom: output)
      defer { try? reader.close() }
      let data = try reader.read(upToCount: 16_384) ?? Data()
      let detail = String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw AgentFailure(message: "工作树\(phase.label)失败（退出码 \(process.terminationStatus)）。\n\(detail)")
    }
  }
}
