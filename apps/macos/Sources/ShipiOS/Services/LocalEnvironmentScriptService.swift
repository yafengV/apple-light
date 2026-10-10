import Foundation

enum LocalEnvironmentScriptService {
  enum Phase { case setup, cleanup
    var label: String { self == .setup ? "初始化" : "清理" }
  }

  static func run(_ script: String, phase: Phase, source: URL, worktree: URL,
    supervisorExecutable: URL? = nil, timeoutSeconds: Int = 600) async throws {
    let task = Task.detached(priority: .userInitiated) {
      try runProcess(script, phase: phase, source: source, worktree: worktree,
        supervisorExecutable: supervisorExecutable, timeoutSeconds: timeoutSeconds)
    }
    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private static func runProcess(_ script: String, phase: Phase, source: URL,
    worktree: URL, supervisorExecutable: URL?, timeoutSeconds: Int) throws {
    try Task<Never, Never>.checkCancellation()
    let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/shipios-agent")
    // SwiftPM and the foreground test host use the same real helper as script/test.sh.
    let executable = supervisorExecutable ?? (FileManager.default.isExecutableFile(atPath: bundled.path)
      ? bundled : ProcessInfo.processInfo.environment["SHIPIOS_TEST_AGENT"].map { URL(fileURLWithPath: $0) } ?? bundled)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("shipios-environment-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let request = directory.appendingPathComponent("request.json")
    try JSONSerialization.data(withJSONObject: ["script": script, "source": source.path,
      "worktree": worktree.path, "phase": phase == .setup ? "setup" : "cleanup",
      "timeoutSeconds": timeoutSeconds]).write(to: request)
    let output = directory.appendingPathComponent("result.json")
    guard FileManager.default.createFile(atPath: output.path, contents: nil,
      attributes: [.posixPermissions: 0o600]) else {
      throw AgentFailure(message: "无法创建工作树\(phase.label)日志。")
    }
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = executable
    process.arguments = ["run-local-environment", "--request-file", request.path]
    process.currentDirectoryURL = phase == .setup ? worktree : source
    var environment = ProcessInfo.processInfo.environment
    environment["CODEX_SOURCE_TREE_PATH"] = source.path
    environment["CODEX_WORKTREE_PATH"] = worktree.path
    process.environment = environment
    let lifetime = Pipe()
    process.standardInput = lifetime
    defer { try? lifetime.fileHandleForWriting.close() }
    process.standardOutput = handle
    process.standardError = handle
    try Task<Never, Never>.checkCancellation()
    try process.run()
    try lifetime.fileHandleForReading.close()
    let deadline = Date().addingTimeInterval(Double(timeoutSeconds) + 5)
    while process.isRunning && Date() < deadline && !Task<Never, Never>.isCancelled {
      Thread.sleep(forTimeInterval: 0.1)
    }
    let timedOut = Date() >= deadline
    if process.isRunning {
      // Closing the only parent writer lets the supervisor reap the entire script group.
      try? lifetime.fileHandleForWriting.close()
      let cleanupDeadline = Date().addingTimeInterval(3)
      while process.isRunning && Date() < cleanupDeadline { Thread.sleep(forTimeInterval: 0.05) }
      if process.isRunning { process.terminate(); Thread.sleep(forTimeInterval: 1.5) }
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    process.waitUntilExit()
    try Task<Never, Never>.checkCancellation()
    if timedOut { throw AgentFailure(message: "工作树\(phase.label)超过 10 分钟，请检查脚本。") }
    let data = try Data(contentsOf: output)
    guard process.terminationStatus == 0, let result = try? JSONDecoder().decode(ScriptResult.self, from: data) else {
      throw AgentFailure(message: "工作树\(phase.label)进程管理器失败（退出码 \(process.terminationStatus)）。\n"
        + String(decoding: data.prefix(16_384), as: UTF8.self))
    }
    if result.cancelled { throw CancellationError() }
    if result.timedOut { throw AgentFailure(message: "工作树\(phase.label)超过 10 分钟，请检查脚本。") }
    guard result.exitCode == 0 else {
      let detail = String((result.stdout + "\n" + result.stderr).prefix(16_384))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw AgentFailure(message: "工作树\(phase.label)失败（退出码 \(result.exitCode.map(String.init) ?? "未知")）。\n\(detail)")
    }
  }

  private struct ScriptResult: Decodable {
    let exitCode: Int?
    let cancelled: Bool
    let timedOut: Bool
    let stdout: String
    let stderr: String
  }
}
