import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

extension WorkspaceStore {
  func counterProjectRoot(taskID: String) -> URL? {
    guard let task = library.tasks.first(where: { $0.id == taskID }), !task.project.isEmpty else { return nil }
    return URL(fileURLWithPath: library.primaryFolder(for: task.project), isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL
  }

  func counterProject(taskID: String) -> URL? {
    guard let root = counterProjectRoot(taskID: taskID) else { return nil }
    guard FileManager.default.fileExists(atPath: root.appendingPathComponent("HelloShipiOSUITests.swift").path),
      FileManager.default.fileExists(atPath: root.appendingPathComponent("HelloShipiOS.xcodeproj").path) else { return nil }
    return root
  }

  func canVerifyCounter(taskID: String) -> Bool {
    guard let project = counterProject(taskID: taskID), !shuttingDown, !libraryRecoveryBlocksInteraction,
      counterDeliveryTasks[taskID] == nil, activeRun(taskID: taskID) == nil,
      let task = library.tasks.first(where: { $0.id == taskID }), !task.archived,
      !activityArchivingTaskIDs.contains(taskID), !handoffBlocksProject(task.project),
      library.goalSessions[taskID]?.status != .active else { return false }
    if let workspace = task.codexWorkspacePath,
      URL(fileURLWithPath: workspace).resolvingSymlinksInPath().standardizedFileURL != project { return false }
    return !library.counterDeliveries.values.contains { $0.phase.isActive }
      && activeLocalRun == nil
  }

  func canRepairCounter(taskID: String) -> Bool {
    let config = modelConfiguration(for: taskID)
    return canVerifyCounter(taskID: taskID) && !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && config.apiProtocol == .codexResponses && (try? config.endpoint("responses")) != nil
  }

  func beginCounterDelivery(taskID: String, repairFailures: Bool) {
    guard canVerifyCounter(taskID: taskID), let project = counterProject(taskID: taskID) else { return }
    let config = modelConfiguration(for: taskID)
    guard !repairFailures || canRepairCounter(taskID: taskID) else {
      error = "自动修复需要已配置并支持 Core 工具的 Responses 服务。"
      return
    }
    var state = CounterDelivery(id: UUID(), taskID: taskID, project: project.path, startedAt: Date())
    state.model = config.model
    state.serviceHost = URL(string: config.baseURL)?.host ?? ""
    if let run = taskWindowRuns(taskID).last(where: { $0.kind == "chat" && $0.status == "succeeded" }) {
      state.modelRunIDs = [run.id]
    }
    let operation = state.id
    library.counterDeliveries[taskID] = state
    guard saveLibrary() else {
      library.counterDeliveries[taskID]?.phase = .failed
      library.counterDeliveries[taskID]?.message = "无法保存验证状态，未启动验证。"
      return
    }
    counterDeliveryTasks[taskID] = Task { [weak self] in
      guard let self else { return }
      _ = await CounterDeliveryOperation.run(state, repairFailures: repairFailures,
        verify: {
          try Task.checkCancellation()
          return try await self.runCounterVerification(project: project, taskID: taskID, operation: operation)
        }, repair: { prompt in
          try Task.checkCancellation()
          guard self.modelConfiguration(for: taskID) == config, !self.shuttingDown,
            self.library.counterDeliveries[taskID]?.id == operation,
            self.counterProject(taskID: taskID) == project else {
            throw AgentFailure(message: "服务或项目已变化；停止修复，保留现有结果。")
          }
          guard let runID = await self.startChat(prompt, taskID: taskID, counterRepairOperation: operation) else {
            throw AgentFailure(message: "模型修复未能启动，请查看聊天中的配置或连接错误。")
          }
          let model = self.modelTask(runID: runID)
          await withTaskCancellationHandler {
            await model?.value
          } onCancel: { model?.cancel() }
          try Task.checkCancellation()
          guard self.library.chatRuns.first(where: { $0.id == runID })?.status == "succeeded" else {
            throw AgentFailure(message: "模型修复未成功，请查看对应聊天；未继续自动尝试。")
          }
          return runID
        }, publish: { updated in
          guard self.library.counterDeliveries[taskID]?.id == operation else { return false }
          var updated = updated
          let sameProject = self.counterProjectRoot(taskID: taskID) == project
          if !sameProject {
            updated.phase = .cancelled; updated.finishedAt = Date()
            updated.message = "任务工程已变化，已停止原工程验证；工件保留。"
          }
          self.library.counterDeliveries[taskID] = updated
          guard self.saveLibrary() else { return false }
          do {
            let reports = self.dataRoot.appendingPathComponent("CounterReports", isDirectory: true)
            try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: reports.appendingPathComponent(updated.id.uuidString + ".json"), options: .atomic)
          } catch { self.error = error.localizedDescription; return false }
          return sameProject
        })
      if self.library.counterDeliveries[taskID]?.id == operation { self.counterDeliveryTasks[taskID] = nil }
    }
  }

  func stopCounterDelivery(taskID: String) {
    counterDeliveryTasks[taskID]?.cancel()
  }

  private func runCounterVerification(project: URL, taskID: String, operation: UUID) async throws -> AgentRun {
    let runtime = AgentClient()
    let identity = SHA256.hash(data: Data(taskID.utf8)).map { String(format: "%02x", $0) }.joined()
    let directory = dataRoot.appendingPathComponent("CounterVerification/" + identity, isDirectory: true)
    try runtime.start(executable: executable, project: project, dataDirectory: directory)
    runtime.onEvent = { [weak self] event in
      guard let self, self.library.counterDeliveries[taskID]?.id == operation,
        event.kind == "step.started", let stage = event.payload["stage"].text else { return }
      self.library.counterDeliveries[taskID]?.message = ["build": "正在构建 UI 测试", "test": "正在执行 0→1→2→0 断言",
        "boot": "正在启动专用 iOS 设备", "boot_status": "正在准备专用 iOS 设备"][stage] ?? "正在读取验证结果"
    }
    let watchdog = Task {
      do { try await Task.sleep(for: .seconds(810)); await runtime.stop(eofGraceSeconds: 10) }
      catch {}
    }
    defer { watchdog.cancel() }
    var verificationID: String?
    do {
      let result: AgentRun = try await {
        _ = try await runtime.request("initialize", ["protocolVersion": .number(1)], cancelOnTaskCancellation: true)
        let started = try await runtime.request("run.start", ["kind": .string("verify_counter")], cancelOnTaskCancellation: true).decode(AgentRun.self)
        verificationID = started.id
        while true {
          try Task.checkCancellation()
          guard library.counterDeliveries[taskID]?.id == operation,
            counterProjectRoot(taskID: taskID) == project else { throw CancellationError() }
          let run = try await runtime.request("run.get", ["runId": .string(started.id)], cancelOnTaskCancellation: true).decode(AgentRun.self)
          if !run.isActive { return run }
          try await Task.sleep(for: .milliseconds(150))
        }
      }()
      await runtime.stop()
      return result
    } catch {
      // A cancelled caller's sleeps return immediately. Reap owned compiler children
      // in an uncancelled task so the EOF grace period actually takes effect.
      let cleanup = Task { @MainActor () -> AgentRun? in
        var terminal: AgentRun?
        if error is CancellationError, let verificationID {
          _ = try? await runtime.request("run.cancel", ["runId": .string(verificationID)])
          let deadline = ContinuousClock.now.advanced(by: .seconds(10))
          while ContinuousClock.now < deadline {
            guard let result = try? await runtime.request("run.get", ["runId": .string(verificationID)]).decode(AgentRun.self) else { break }
            if !result.isActive { terminal = result; break }
            try? await Task.sleep(for: .milliseconds(100))
          }
        }
        await runtime.stop(eofGraceSeconds: 10)
        return terminal
      }
      if let terminal = await cleanup.value { return terminal }
      throw error
    }
  }

  func exportCounterDelivery(taskID: String) async {
    guard let record = library.counterDeliveries[taskID], !record.phase.isActive,
      let window = NSApp.keyWindow else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "shipios-counter-\(record.id).json"
    let response = await withCheckedContinuation { continuation in
      panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
    }
    if response == .OK, let url = panel.url {
      do { try JSONEncoder().encode(record).write(to: url, options: .atomic) }
      catch { self.error = error.localizedDescription }
    }
  }
}
