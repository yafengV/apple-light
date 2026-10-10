import Foundation
import CryptoKit

/// Routes Codex turns through independent, project-owned Agent processes.
@MainActor
final class CodexChatTransport {
  var onBrowserRequest: ((String, UUID, JSONValue) -> Void)?
  var onRuntimeCommandEvent: ((String, String?, JSONValue) -> Void)?
  var onSubagentEvent: ((String, String?, JSONValue) -> Void)?
  var onSubagentSubmission: ((SubagentSubmission) throws -> Void)?
  var onSubagentSnapshot: ((String, String?, JSONValue) -> Void)?
  var onThreadDisconnected: ((String) -> Void)?
  var onHookEvent: ((String, String?, JSONValue) -> Void)?
  var onThreadStarted: ((String, String, String) -> Void)?
  private struct ServiceIdentity: Equatable {
    let endpoint: String
    let keyDigest: Data?
    let mcpDigest: Data
    let hooksDigest: Data
    let additionalFolders: [String]
    let permissionProfileID: String?
    let permissionProfileDigest: Data?
    let pauseAutomationID: UUID?
    let confettiEnabled: Bool
    let readOnly: Bool

    init(config: ModelConfiguration, key: String?, mcpData: Data, hooksData: Data, additionalFolders: [String],
      permissionProfile: AgentNamedPermissionProfile?, confettiEnabled: Bool, pauseAutomationID: UUID?,
      readOnly: Bool) {
      endpoint = config.credentialAccount
      keyDigest = key.map { Data(SHA256.hash(data: Data($0.utf8))) }
      mcpDigest = Data(SHA256.hash(data: mcpData))
      hooksDigest = Data(SHA256.hash(data: hooksData))
      self.additionalFolders = additionalFolders
      permissionProfileID = permissionProfile?.id
      permissionProfileDigest = permissionProfile.map {
        Data(SHA256.hash(data: Data($0.configTOML.utf8)))
      }
      self.confettiEnabled = confettiEnabled
      self.pauseAutomationID = pauseAutomationID
      self.readOnly = readOnly
    }
  }

  private let dataRoot: URL
  private var clients: [String: AgentClient] = [:]
  private final class ClientStartup {
    let id = UUID()
    var task: Task<Void, Never>?
    var waiters: [UUID: CheckedContinuation<AgentClient, Error>] = [:]
  }
  private var startingClients: [String: ClientStartup] = [:]
  // Includes cancelled startups until their process cleanup finishes.
  private var startupTasks: [UUID: Task<Void, Never>] = [:]
  private var taskProjects: [String: String] = [:]
  private struct NativeMessageCursor {
    var attempts: [String: String] = [:]
    var published: [String: String] = [:]
  }
  private var nativeMessages: [String: NativeMessageCursor] = [:]
  private var generation = UUID()
  private var activeThreads: Set<String> = []
  private var serviceIdentities: [String: ServiceIdentity] = [:]
  private var preparingTasks: Set<String> = []
  private var streams: [String: AsyncThrowingStream<JSONValue, Error>.Continuation] = [:]
  private var activeTurnIDs: [String: String] = [:]
  private var turnTokens: [String: UUID] = [:]
  private var interruptingTurns: [String: (token: UUID, task: Task<Void, Never>)] = [:]
  private var browserTurnTokens: [String: UUID] = [:]

  init(dataRoot: URL) {
    self.dataRoot = dataRoot
  }

  private func client(for taskID: String) throws -> AgentClient {
    guard let project = taskProjects[taskID], let client = clients[project] else {
      throw AgentFailure(message: "Codex 会话所属项目已断开。")
    }
    return client
  }

  private func prepareClient(taskID: String, workspace: URL,
    executable: URL) async throws -> AgentClient {
    try Task.checkCancellation()
    let canonical = workspace.resolvingSymlinksInPath().standardizedFileURL
    var directory: ObjCBool = false
    guard canonical.isFileURL, canonical.path.hasPrefix("/"),
      FileManager.default.fileExists(atPath: canonical.path, isDirectory: &directory),
      directory.boolValue else {
      throw AgentFailure(message: "Codex 任务目录不可用，请检查项目或工作树。")
    }
    let path = canonical.path
    guard taskProjects[taskID].map({ $0 == path }) ?? true else {
      throw AgentFailure(message: "已有 Codex 会话不能更换任务目录。")
    }
    if let client = clients[path] {
      taskProjects[taskID] = path
      return client
    }
    let token = generation, waiterID = UUID()
    let startup = startingClients[path] ?? ClientStartup()
    let client: AgentClient = try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
        startingClients[path] = startup
        startup.waiters[waiterID] = continuation
        if startup.task == nil {
          let task = Task {
            defer { startup.task = nil; startupTasks.removeValue(forKey: startup.id) }
            let result: Result<AgentClient, Error>
            do {
              result = .success(try await launchClient(path: path, workspace: canonical, executable: executable))
            } catch { result = .failure(error) }
            await finishStartup(startup, path: path, token: token, result: result)
          }
          startup.task = task
          startupTasks[startup.id] = task
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancelStartupWaiter(startup, path: path, id: waiterID) }
    }
    try Task.checkCancellation()
    guard generation == token else { throw CancellationError() }
    taskProjects[taskID] = path
    return client
  }

  private func cancelStartupWaiter(_ startup: ClientStartup, path: String, id: UUID) {
    guard let waiter = startup.waiters.removeValue(forKey: id) else { return }
    if startup.waiters.isEmpty {
      if startingClients[path] === startup { startingClients.removeValue(forKey: path) }
      startup.task?.cancel()
    }
    waiter.resume(throwing: CancellationError())
  }

  private func finishStartup(_ startup: ClientStartup, path: String, token: UUID,
    result: Result<AgentClient, Error>) async {
    guard generation == token, startingClients[path] === startup else {
      if case .success(let client) = result { await Task { await client.stop() }.value }
      return
    }
    startingClients.removeValue(forKey: path)
    let waiters = Array(startup.waiters.values)
    startup.waiters.removeAll()
    switch result {
    case .success(let client):
      clients[path] = client
      for waiter in waiters { waiter.resume(returning: client) }
    case .failure(let error):
      for waiter in waiters { waiter.resume(throwing: error) }
    }
  }

  private func launchClient(path: String, workspace: URL,
    executable: URL) async throws -> AgentClient {
    let digest = SHA256.hash(data: Data(path.utf8))
      .map { String(format: "%02x", $0) }.joined()
    let projectData = dataRoot.appendingPathComponent("Projects/\(digest)", isDirectory: true)
    let processData = dataRoot.appendingPathComponent("CodexAgents/\(digest)", isDirectory: true)
    let client = AgentClient()
    // A retired process can still emit notifications while stdout drains.
    // Route only the client currently registered for this project.
    client.onCodexEvent = { [weak self, weak client] event in
      guard let self, let client, self.clients[path] === client else { return }
      self.receive(event)
    }
    client.onCodexGap = { [weak self, weak client] in
      guard let self, let client, self.clients[path] === client else { return }
      self.reset(project: path,
        error: AgentFailure(message: "Codex 事件流中断，本轮回复无法完整确认。"))
    }
    client.onDisconnect = { [weak self, weak client] message in
      guard let self, let client, self.clients[path] === client else { return }
      self.reset(project: path, error: AgentFailure(message: message))
    }
    try Task.checkCancellation()
    try client.start(executable: executable, project: workspace,
      dataDirectory: processData, codexDataDirectory: projectData)
    do {
      let hello = try await client.request("initialize", ["protocolVersion": .number(1)],
        cancelOnTaskCancellation: true)
      guard hello["protocolVersion"].int == 1 else {
        throw AgentFailure(message: "不支持的 Agent 协议版本")
      }
    } catch {
      // An uninitialized process cannot handle EOF yet. Use an uncancelled
      // cleanup task so termination still waits for the actual process exit.
      let cancelled = Task.isCancelled
      await Task { await client.stop(waitForEOF: !cancelled) }.value
      throw error
    }
    return client
  }

  func startTurn(
    taskID: String, workspace: URL, executable: URL, additionalFolders: [String] = [],
    config: ModelConfiguration, key: String?,
    initialText: String, continuationText: String, images: [ImageAttachment],
    fileAppendix: String?, readOnly: Bool = false, textOnly: Bool = false, planMode: Bool = false,
    goalInstructions: String? = nil, mcpServers: [MCPServerConfiguration], hooks: [HookSourceBinding] = [],
    permissions: AgentRuntimePreferences, responses: AgentResponsePreferences,
    webSearchMode: AgentWebSearchMode, confettiEnabled: Bool = false, pauseAutomationID: UUID? = nil,
    compact: Bool = false, connectOnly: Bool = false, forkOrigin: CodexForkOrigin? = nil,
    resumeOrigin: CodexResumeOrigin? = nil, createForkOnly: Bool = false,
    initializeOnly: Bool = false, onThreadInitialized: ((String, String) -> Void)? = nil,
    onForkCreated: ((String, String) -> Void)? = nil
  ) async throws -> AsyncThrowingStream<JSONValue, Error> {
    try Task.checkCancellation()
    if initializeOnly {
      guard forkOrigin == nil, resumeOrigin == nil, !createForkOnly, !compact,
        !connectOnly, !textOnly, !activeThreads.contains(taskID),
        initialText.isEmpty, continuationText.isEmpty, images.isEmpty, fileAppendix == nil,
        onThreadInitialized != nil else {
        throw AgentFailure(message: "初始化空聊天不能包含模型输入或历史来源。")
      }
    }
    if createForkOnly {
      guard forkOrigin != nil, resumeOrigin == nil, !compact, !connectOnly, !textOnly,
        !activeThreads.contains(taskID), onForkCreated != nil else {
        throw AgentFailure(message: "创建聊天分支需要独立的新任务和原生历史来源。")
      }
    }
    guard preparingTasks.insert(taskID).inserted else {
      throw AgentFailure(message: "该任务已有 Codex 回合正在运行。")
    }
    defer { preparingTasks.remove(taskID) }
    if let interruption = interruptingTurns[taskID] { await interruption.task.value }
    try Task.checkCancellation()
    guard streams[taskID] == nil else {
      throw AgentFailure(message: "该任务已有 Codex 回合正在运行。")
    }
    let folders = try ProjectFolders.canonical([workspace.path] + additionalFolders)
    let path = workspace.resolvingSymlinksInPath().standardizedFileURL.path
    if let previous = taskProjects[taskID], previous != path {
      await stop(taskID: taskID)
      taskProjects.removeValue(forKey: taskID)
    }
    let client = try await prepareClient(taskID: taskID, workspace: workspace,
      executable: executable)
    guard continuationText.utf8.count <= 48_000 else {
      throw AgentFailure(message: "本轮文字超过 Codex 通道的 48 KiB 上限，请缩短后重试。")
    }
    let enabledServers = try mcpServers.filter(\.enabled).map { try $0.validated() }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let mcpData = try encoder.encode(enabledServers)
    let mcpValue = try JSONDecoder().decode(JSONValue.self, from: mcpData)
    let effectiveHooks = textOnly ? [] : hooks
    let hooksData = try encoder.encode(effectiveHooks)
    let token = generation
    let selectedProfile = readOnly || textOnly ? nil : permissions.namedProfile
    let service = ServiceIdentity(config: config, key: key, mcpData: mcpData, hooksData: hooksData,
      additionalFolders: Array(folders.dropFirst()), permissionProfile: selectedProfile,
      confettiEnabled: confettiEnabled, pauseAutomationID: pauseAutomationID, readOnly: readOnly || textOnly)
    if activeThreads.contains(taskID), serviceIdentities[taskID] != service {
      _ = try await client.request("codex.thread.stop", ["taskId": .string(taskID)])
      guard generation == token else { throw CancellationError() }
      onThreadDisconnected?(taskID)
      activeThreads.remove(taskID)
      activeTurnIDs.removeValue(forKey: taskID)
      serviceIdentities.removeValue(forKey: taskID)
    }
    let staged = try fileAppendix.map(stageText)
    defer { if let staged { try? FileManager.default.removeItem(at: staged.url) } }
    let (stream, continuation) = AsyncThrowingStream<JSONValue, Error>.makeStream()
    streams[taskID] = continuation
    nativeMessages[taskID] = NativeMessageCursor()
    turnTokens[taskID] = UUID()
    browserTurnTokens[taskID] = UUID()
    do {
      let firstTurn = !activeThreads.contains(taskID)
      var sendFullContext = firstTurn
      if firstTurn {
        let hooksAttachment = effectiveHooks.isEmpty ? nil : try HookStaging.stage(effectiveHooks, root: dataRoot)
        defer { hooksAttachment?.remove() }
        var threadParameters: [String: JSONValue] = [
          "taskId": .string(taskID), "baseUrl": .string(config.baseURL),
          "model": .string(config.model), "apiKey": key.map(JSONValue.string) ?? .null,
          "initialContextBytes": .number(Double(compact ? 0 : initialText.utf8.count)),
          "resumeOnly": .bool(compact || connectOnly),
          "createForkOnly": .bool(createForkOnly),
          "readOnly": .bool(readOnly), "textOnly": .bool(textOnly),
          "permissionProfileId": selectedProfile.map { .string($0.id) } ?? .null,
          "permissionProfileConfig": selectedProfile.map { .string($0.configTOML) } ?? .null,
          "permissionProfileSelectionExplicit": .bool(true),
          "permissionsSelectionExplicit": .bool(true),
          "additionalFolders": .array(folders.dropFirst().map(JSONValue.string)),
          "permissions": .object([
            "approvalPolicy": .string(permissions.approvalPolicy.rawValue),
            "approvalReviewer": .string(permissions.approvalReviewer.rawValue),
            "sandboxMode": .string(permissions.sandboxMode.rawValue),
            "networkAccess": .bool(permissions.networkAccess),
          ]),
          "responses": .object([
            "verbosity": responses.verbosity == .modelDefault
              ? .null : .string(responses.verbosity.rawValue),
            "reasoningSummary": .string(responses.reasoningSummary.rawValue),
          ]),
          "webSearch": .object([
            "mode": .string(config.supportsHostedWebSearch ? webSearchMode.rawValue : AgentWebSearchMode.disabled.rawValue),
            "supportsHostedWebSearch": .bool(config.supportsHostedWebSearch),
          ]),
          "mcpServers": mcpValue,
          "confettiEnabled": .bool(confettiEnabled),
          "pauseAutomationId": pauseAutomationID.map { .string($0.uuidString) } ?? .null,
          "forkOrigin": forkOrigin?.wireValue ?? .null,
          "resumeOrigin": resumeOrigin?.wireValue ?? .null,
        ]
        if let hooksAttachment { threadParameters["hooksAttachment"] = hooksAttachment.wireValue }
        let thread = try await client.request("codex.thread.start", threadParameters)
        guard generation == token else { throw CancellationError() }
        sendFullContext = thread["resumed"].boolean != true && thread["forked"].boolean != true
        activeThreads.insert(taskID)
        serviceIdentities[taskID] = service
        if createForkOnly {
          guard thread["forked"].boolean == true,
            thread["resumed"].boolean == false || thread["forkRecovered"].boolean == true,
            let threadID = thread["threadId"].text, UUID(uuidString: threadID) != nil,
            threadID != forkOrigin?.threadID else {
            throw AgentFailure(message: "Core 未确认独立聊天分支，原聊天未被更改。")
          }
          if thread["historyWorkspace"] != .null {
            guard let reported = thread["historyWorkspace"].text, reported.hasPrefix("/"),
              URL(fileURLWithPath: reported).resolvingSymlinksInPath().standardizedFileURL.path == path else {
              throw AgentFailure(message: "Core 返回的聊天分支目录与目标工作区不一致，请重试。")
            }
          }
          try Task.checkCancellation()
          onForkCreated?(threadID, path)
        } else if initializeOnly {
          guard let threadID = thread["threadId"].text, UUID(uuidString: threadID) != nil,
            thread["forked"].boolean != true else {
            throw AgentFailure(message: "Core 未确认空聊天来源，请重试。")
          }
          if thread["historyWorkspace"] != .null {
            guard let reported = thread["historyWorkspace"].text, reported.hasPrefix("/"),
              URL(fileURLWithPath: reported).resolvingSymlinksInPath().standardizedFileURL.path == path else {
              throw AgentFailure(message: "Core 返回的空聊天目录与来源工作区不一致，请重试。")
            }
          }
          try Task.checkCancellation()
          onThreadInitialized?(threadID, path)
        } else {
          if let threadID = thread["threadId"].text, UUID(uuidString: threadID) != nil {
            onThreadStarted?(taskID, threadID, thread["historyWorkspace"].text ?? path)
            _ = try? await client.request("codex.thread.descendants.refresh", [
              "taskId": .string(taskID), "expectedThreadId": .string(threadID)])
          }
        }
        if compact && sendFullContext {
          throw AgentFailure(message: "Codex 会话记录已不可用，无法整理上下文。")
        }
      }
      if connectOnly || createForkOnly || initializeOnly {
        streams.removeValue(forKey: taskID)?.finish()
        nativeMessages.removeValue(forKey: taskID)
        turnTokens.removeValue(forKey: taskID); browserTurnTokens.removeValue(forKey: taskID)
        return stream
      }
      if compact {
        _ = try await client.request("codex.turn.compact", ["taskId": .string(taskID)])
        guard generation == token else { throw CancellationError() }
        try Task.checkCancellation()
        return stream
      }
      let wireImages: [JSONValue] = images.map { image in .object([
        "id": .string(image.id.uuidString),
        "fileExtension": .string(image.fileExtension),
        "byteCount": .number(Double(image.byteCount)),
      ]) }
      var request: [String: JSONValue] = [
        "taskId": .string(taskID),
        "text": .string(sendFullContext ? initialText : continuationText),
        "images": .array(wireImages),
        "planMode": .bool(planMode),
        "model": .string(config.model),
        "reasoningEffort": .string(config.reasoning),
        "permissions": .object([
          "approvalPolicy": .string(permissions.approvalPolicy.rawValue),
          "approvalReviewer": .string(permissions.approvalReviewer.rawValue),
          "sandboxMode": .string(permissions.sandboxMode.rawValue),
          "networkAccess": .bool(permissions.networkAccess),
        ]),
      ]
      if let goalInstructions { request["goalInstructions"] = .string(goalInstructions) }
      if let staged {
        request["textAttachment"] = .object([
          "id": .string(staged.id.uuidString), "byteCount": .number(Double(staged.byteCount)),
        ])
      }
      let submitted = try await client.request("codex.turn.submit", request)
      guard generation == token else { throw CancellationError() }
      if streams[taskID] != nil { activeTurnIDs[taskID] = submitted["turnId"].text }
      try Task.checkCancellation()
      return stream
    } catch {
      if createForkOnly || initializeOnly {
        // Release only this newly initialized task, even when its caller was
        // cancelled. Existing source threads and the project process stay alive.
        await Task { await self.discard(taskID: taskID) }.value
      } else if Task.isCancelled { await interrupt(taskID: taskID) }
      browserTurnTokens.removeValue(forKey: taskID)
      turnTokens.removeValue(forKey: taskID)
      streams.removeValue(forKey: taskID)?.finish(throwing: error)
      nativeMessages.removeValue(forKey: taskID)
      throw error
    }
  }

  func steer(taskID: String, text: String, images: [ImageAttachment],
    fileAppendix: String?) async throws -> Bool {
    guard activeThreads.contains(taskID), streams[taskID] != nil,
      let expectedTurnID = activeTurnIDs[taskID] else { return false }
    guard text.utf8.count <= 48_000 else {
      throw AgentFailure(message: "追加文字超过 Codex 通道的 48 KiB 上限，请缩短后重试。")
    }
    let token = generation
    let staged = try fileAppendix.map(stageText)
    defer { if let staged { try? FileManager.default.removeItem(at: staged.url) } }
    var request: [String: JSONValue] = [
      "taskId": .string(taskID), "expectedTurnId": .string(expectedTurnID),
      "text": .string(text),
      "images": .array(images.map { image in .object([
        "id": .string(image.id.uuidString),
        "fileExtension": .string(image.fileExtension),
        "byteCount": .number(Double(image.byteCount)),
      ]) }),
    ]
    if let staged {
      request["textAttachment"] = .object([
        "id": .string(staged.id.uuidString), "byteCount": .number(Double(staged.byteCount)),
      ])
    }
    let result = try await client(for: taskID).request("codex.turn.steer", request)
    guard generation == token else { throw CancellationError() }
    return result["steered"].boolean == true
  }

  func canSteer(taskID: String) -> Bool {
    streams[taskID] != nil && activeTurnIDs[taskID] != nil
  }

  func turnToken(taskID: String) -> UUID? { turnTokens[taskID] }

  func interrupt(taskID: String) async {
    guard let token = turnTokens[taskID] else { return }
    await interrupt(taskID: taskID, expectedToken: token)
  }

  /// Core acknowledges submission before TurnAborted is published. Keep the
  /// transport occupied until that boundary, and coalesce cancellation paths.
  func interrupt(taskID: String, expectedToken: UUID) async {
    guard turnTokens[taskID] == expectedToken, activeThreads.contains(taskID) else { return }
    browserTurnTokens.removeValue(forKey: taskID)
    if let pending = interruptingTurns[taskID], pending.token == expectedToken {
      await pending.task.value
      return
    }
    let cleanup = Task { @MainActor [weak self] in
      guard let self, self.turnTokens[taskID] == expectedToken else { return }
      _ = try? await self.client(for: taskID).request("codex.turn.interrupt", ["taskId": .string(taskID)])
      let deadline = ContinuousClock.now.advanced(by: .seconds(10))
      while self.turnTokens[taskID] == expectedToken, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
      }
      // A missing terminal notification must not leave an unusable stream or
      // let another turn reuse an uncertain runtime. Closing preserves rollout.
      if self.turnTokens[taskID] == expectedToken { await self.stop(taskID: taskID) }
    }
    interruptingTurns[taskID] = (expectedToken, cleanup)
    await cleanup.value
    if interruptingTurns[taskID]?.token == expectedToken {
      interruptingTurns.removeValue(forKey: taskID)
    }
  }

  func stop(taskID: String) async {
    browserTurnTokens.removeValue(forKey: taskID)
    guard activeThreads.contains(taskID) else { return }
    _ = try? await client(for: taskID).request("codex.thread.stop", ["taskId": .string(taskID)])
    onThreadDisconnected?(taskID)
    activeThreads.remove(taskID)
    serviceIdentities.removeValue(forKey: taskID)
    activeTurnIDs.removeValue(forKey: taskID)
    turnTokens.removeValue(forKey: taskID)
    streams.removeValue(forKey: taskID)?.finish()
    nativeMessages.removeValue(forKey: taskID)
  }

  /// Interrupt ends a model turn while unified-exec sessions can stay alive.
  /// Explicit cleanup targets that task's Core session, preserving its history.
  func cleanBackgroundTerminals(taskID: String) async throws {
    guard activeThreads.contains(taskID) else { throw AgentFailure(message: "Codex 会话未连接") }
    _ = try await client(for: taskID).request("codex.thread.backgroundTerminals.clean", ["taskId": .string(taskID)])
  }

  func interruptDescendants(taskID: String, expectedThreadID: String) async throws {
    guard activeThreads.contains(taskID) else { throw AgentFailure(message: "Codex 会话未连接") }
    _ = try await client(for: taskID).request("codex.thread.descendants.interrupt", [
      "taskId": .string(taskID), "expectedThreadId": .string(expectedThreadID)])
  }

  func isConnected(taskID: String) -> Bool { activeThreads.contains(taskID) }

  func waitForParentPreparation(taskID: String) async throws {
    while preparingTasks.contains(taskID) {
      try await Task.sleep(for: .milliseconds(20))
    }
    try Task.checkCancellation()
  }

  func refreshSubagents(taskID: String, rootThreadID: String) async throws {
    guard activeThreads.contains(taskID) else { throw AgentFailure(message: "父会话尚未连接。") }
    let token = generation
    _ = try await client(for: taskID).request("codex.thread.descendants.refresh", [
      "taskId": .string(taskID), "expectedThreadId": .string(rootThreadID)])
    guard generation == token, activeThreads.contains(taskID) else { throw CancellationError() }
    try Task.checkCancellation()
  }

  func loadSubagent(taskID: String, rootThreadID: String, childThreadID: String) async throws -> JSONValue {
    guard activeThreads.contains(taskID) else { throw AgentFailure(message: "父会话尚未连接。") }
    let token = generation
    let response = try await client(for: taskID).request("codex.subagent.load", [
      "taskId": .string(taskID), "expectedThreadId": .string(rootThreadID), "childThreadId": .string(childThreadID)])
    guard token == generation, activeThreads.contains(taskID), response["rootThreadId"].text == rootThreadID,
      response["agent"]["threadId"].text == childThreadID else { throw CancellationError() }
    try Task.checkCancellation()
    return response["agent"]
  }

  func readSubagentHistory(taskID: String, rootThreadID: String, childThreadID: String) async throws -> [JSONValue] {
    guard activeThreads.contains(taskID) else { throw AgentFailure(message: "父会话尚未连接，恢复会话后可重新加载子任务。") }
    let client = try client(for: taskID), token = generation
    var snapshot: String?, digest: String?, total: Int?, bytes = Data(), offset = 0
    repeat {
      try Task.checkCancellation()
      let page = try await client.request("codex.subagent.history.read", [
        "taskId": .string(taskID), "expectedThreadId": .string(rootThreadID),
        "childThreadId": .string(childThreadID), "offset": .number(Double(offset)),
        "snapshotId": snapshot.map(JSONValue.string) ?? .null])
      guard token == generation, activeThreads.contains(taskID) else { throw CancellationError() }
      guard page["rootThreadId"].text == rootThreadID, page["childThreadId"].text == childThreadID,
        let id = page["snapshotId"].text, UUID(uuidString: id) != nil,
        let hash = page["sha256"].text, hash.count == 64,
        let count = page["totalBytes"].int, count >= 0,
        page["offset"].int == offset, let next = page["nextOffset"].int,
        let done = page["done"].boolean, let chunk = page["chunk"].text,
        chunk.utf8.count <= 48 * 1024, next == offset + chunk.utf8.count,
        next <= count, done == (next == count), done || next > offset,
        snapshot == nil || (snapshot == id && digest == hash && total == count) else {
        throw AgentFailure(message: "子任务历史分块不完整或身份已变化，请重新加载。")
      }
      snapshot = id; digest = hash; total = count
      bytes.append(contentsOf: chunk.utf8); offset = next
      if done { break }
    } while true
    guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == digest else {
      throw AgentFailure(message: "子任务历史校验失败，请重新加载。")
    }
    try Task.checkCancellation()
    return try JSONDecoder().decode([JSONValue].self, from: bytes)
  }

  func submitSubagent(taskID: String, rootThreadID: String, childThreadID: String,
    text: String, expectedTurnID: String?, images: [ImageAttachment] = [], files: [FileAttachment] = []) async throws -> String {
    guard activeThreads.contains(taskID) else { throw AgentFailure(message: "父会话尚未连接。") }
    guard text.utf8.count <= 48_000, images.count <= ImageAttachmentStorage.maxCount else {
      throw AgentFailure(message: "子任务文字超过 48,000 字节或图片超过 8 张。")
    }
    var imageBytes = 0
    for image in images {
      imageBytes += try ImageAttachmentStorage.data(image, root: dataRoot).count
      guard imageBytes <= ImageAttachmentStorage.maxRequestBytes else { throw AgentFailure(message: "图片上下文超过 32 MiB。") }
    }
    var fileBytes = 0
    let appendix = try FileAttachmentStorage.content(.init(role: "user",
      content: AppshotContext.modelContent("", images: images), files: files), root: dataRoot, total: &fileBytes,
      includeLocalPaths: true)
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty || !files.isEmpty else {
      throw AgentFailure(message: "子任务消息为空。")
    }
    let staged = appendix.isEmpty ? nil : try stageText(appendix)
    defer { if let staged { try? FileManager.default.removeItem(at: staged.url) } }
    var request: [String: JSONValue] = [
      "taskId": .string(taskID), "expectedThreadId": .string(rootThreadID),
      "childThreadId": .string(childThreadID), "text": .string(text),
      "expectedTurnId": expectedTurnID.map(JSONValue.string) ?? .null,
      "images": .array(images.map { .object(["id": .string($0.id.uuidString),
        "fileExtension": .string($0.fileExtension), "byteCount": .number(Double($0.byteCount))]) })]
    if let staged { request["textAttachment"] = .object(["id": .string(staged.id.uuidString), "byteCount": .number(Double(staged.byteCount))]) }
    var record = SubagentSubmission(taskID: taskID, rootThreadID: rootThreadID, childThreadID: childThreadID,
      message: .init(role: "user", content: text, images: images, files: files), wireText: text + appendix,
      expectedTurnID: expectedTurnID)
    try onSubagentSubmission?(record)
    do {
      let response = try await client(for: taskID).request("codex.subagent.submit", request)
      guard let turn = response["turnId"].text, !turn.isEmpty else { throw AgentFailure(message: "子任务没有确认输入。") }
      record.turnID = turn; record.phase = .accepted
      try? onSubagentSubmission?(record)
      return turn
    } catch {
      record.phase = .unconfirmed
      try? onSubagentSubmission?(record)
      throw error
    }
  }

  func interruptSubagent(taskID: String, rootThreadID: String, childThreadID: String, expectedTurnID: String) async throws {
    guard activeThreads.contains(taskID), !expectedTurnID.isEmpty else {
      throw AgentFailure(message: "子任务已断开或当前回合不可用。")
    }
    let response = try await client(for: taskID).request("codex.subagent.interrupt", [
      "taskId": .string(taskID), "expectedThreadId": .string(rootThreadID),
      "childThreadId": .string(childThreadID), "expectedTurnId": .string(expectedTurnID)])
    guard response["interrupted"].boolean == true else {
      throw AgentFailure(message: "子任务回合已结束或发生变化，请重新加载。")
    }
  }

  func resolveSubagentElicitation(taskID: String, rootThreadID: String, childThreadID: String,
    request: SubagentElicitationRequest, choice: SubagentElicitationRequest.Choice, content: JSONValue?) async throws {
    guard activeThreads.contains(taskID), request.allows(choice, content: content) else { throw AgentFailure(message: "MCP 请求已断开或响应无效。") }
    let response = try await client(for: taskID).request("codex.subagent.elicitation.resolve", [
      "taskId": .string(taskID), "expectedThreadId": .string(rootThreadID), "childThreadId": .string(childThreadID),
      "turnId": .string(request.turnID), "requestToken": .string(request.id), "choice": .string(choice.rawValue),
      "content": content ?? .null])
    guard response["resolved"].boolean == true else { throw AgentFailure(message: "子任务 MCP 请求已结束。") }
  }

  func resolveSubagentApproval(taskID: String, rootThreadID: String, childThreadID: String,
    request: SubagentApprovalRequest, choice: Int) async throws {
    guard activeThreads.contains(taskID), request.decisions.indices.contains(choice) else {
      throw AgentFailure(message: "子任务审批已断开或选项已失效。")
    }
    let response = try await client(for: taskID).request("codex.subagent.approval.resolve", [
      "taskId": .string(taskID), "expectedThreadId": .string(rootThreadID),
      "childThreadId": .string(childThreadID), "turnId": .string(request.turnID),
      "requestToken": .string(request.id), "choice": .number(Double(choice))])
    guard response["resolved"].boolean == true else { throw AgentFailure(message: "审批未被确认，请重新加载。") }
  }

  /// Releases an ephemeral thread's local identity after the Core thread stops.
  func discard(taskID: String) async {
    await stop(taskID: taskID)
    taskProjects.removeValue(forKey: taskID)
  }

  func approve(taskID: String, id: String, turnID: String?, patch: Bool,
    decision: MCPApprovalDecision) async throws {
    guard activeThreads.contains(taskID), !id.isEmpty else {
      throw AgentFailure(message: "Codex 审批所属任务已断开。")
    }
    let choice: String
    switch decision {
    case .allowOnce: choice = "allow"
    case .allowTask: choice = "allow_for_session"
    case .deny: choice = "deny"
    }
    _ = try await client(for: taskID).request("codex.turn.approve", [
      "taskId": .string(taskID), "id": .string(id),
      "turnId": turnID.map(JSONValue.string) ?? .null,
      "kind": .string(patch ? "patch" : "exec"),
      "decision": .string(choice),
    ])
  }

  func resolveMCPElicitation(taskID: String, serverName: String, requestID: JSONValue,
    decision: CodexElicitationChoice, content: JSONValue? = nil) async throws {
    guard activeThreads.contains(taskID), !serverName.isEmpty,
      requestID.text != nil || requestID.int != nil else {
      throw AgentFailure(message: "Codex MCP 审批所属任务已断开。")
    }
    _ = try await client(for: taskID).request("codex.elicitation.resolve", [
      "taskId": .string(taskID), "serverName": .string(serverName),
      "requestId": requestID, "decision": .string(decision.rawValue),
      "content": content ?? .null,
    ])
  }

  func answer(taskID: String, turnID: String, answers: [String: [String]]) async throws {
    guard activeThreads.contains(taskID), !turnID.isEmpty else {
      throw AgentFailure(message: "Codex 提问所属任务已断开。")
    }
    _ = try await client(for: taskID).request("codex.turn.answer", [
      "taskId": .string(taskID), "turnId": .string(turnID),
      "answers": .object(answers.mapValues { .array($0.map(JSONValue.string)) }),
    ])
  }

  private func stageText(_ text: String) throws -> (id: UUID, url: URL, byteCount: Int) {
    let bytes = Data(text.utf8)
    guard !bytes.isEmpty, bytes.count <= 1_000_000 else {
      throw AgentFailure(message: "文件提取文本超过 Codex 通道的 1 MB 上限，请减少附件。")
    }
    let directory = dataRoot.appendingPathComponent("CodexStaging", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
      throw AgentFailure(message: "临时附件目录无效。")
    }
    let id = UUID()
    let url = directory.appendingPathComponent(id.uuidString + ".txt")
    do {
      try bytes.write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
      try? FileManager.default.removeItem(at: url)
      throw error
    }
    return (id, url, bytes.count)
  }

  private func reset(_ error: Error) {
    generation = UUID()
    for taskID in activeThreads { onThreadDisconnected?(taskID) }
    activeThreads.removeAll()
    serviceIdentities.removeAll()
    activeTurnIDs.removeAll()
    turnTokens.removeAll()
    browserTurnTokens.removeAll()
    taskProjects.removeAll()
    let pending = Array(streams.values)
    streams.removeAll()
    nativeMessages.removeAll()
    for stream in pending { stream.finish(throwing: error) }
  }

  private func reset(project: String, error: Error) {
    if let client = clients.removeValue(forKey: project) {
      Task { await client.stop() }
    }
    for taskID in taskProjects.filter({ $0.value == project }).map(\.key) {
      onThreadDisconnected?(taskID)
      taskProjects.removeValue(forKey: taskID)
      activeThreads.remove(taskID)
      serviceIdentities.removeValue(forKey: taskID)
      activeTurnIDs.removeValue(forKey: taskID)
      turnTokens.removeValue(forKey: taskID)
      browserTurnTokens.removeValue(forKey: taskID)
      streams.removeValue(forKey: taskID)?.finish(throwing: error)
      nativeMessages.removeValue(forKey: taskID)
    }
  }

  func shutdown() async {
    let starting = Array(startingClients.values)
    startingClients.removeAll()
    for startup in starting {
      startup.task?.cancel()
      let waiters = Array(startup.waiters.values)
      startup.waiters.removeAll()
      for waiter in waiters { waiter.resume(throwing: CancellationError()) }
    }
    reset(CancellationError())
    let running = Array(clients.values)
    clients.removeAll()
    let pendingStartups = Array(startupTasks.values)
    for startup in pendingStartups { await startup.value }
    // Independent project Agents must receive EOF together. Sequential waits
    // accumulate SessionEnd deadlines and can strand another session's cleanup.
    await withTaskGroup(of: Void.self) { group in
      for client in running { group.addTask { @MainActor in await client.stop() } }
      await group.waitForAll()
    }
  }

  func resolveBrowserRequest(taskID: String, requestID: String, result: JSONValue) async throws {
    _ = try await client(for: taskID).request("codex.browser.resolve", [
      "taskId": .string(taskID), "requestId": .string(requestID), "result": result,
    ])
  }

  func resolveAutomationRequest(taskID: String, requestID: String, result: JSONValue) async throws {
    guard streams[taskID] != nil else { throw CancellationError() }
    _ = try await client(for: taskID).request("codex.automation.resolve", [
      "taskId": .string(taskID), "requestId": .string(requestID), "result": result,
    ])
  }

  func browserRequestIsCurrent(taskID: String, token: UUID) -> Bool {
    browserTurnTokens[taskID] == token && streams[taskID] != nil
  }

  func publishBrowserResult(taskID: String, requestID: String, result: JSONValue) {
    streams[taskID]?.yield(.object([
      "type": .string("browser_result"), "requestId": .string(requestID), "result": result,
    ]))
  }

  private func receive(_ payload: JSONValue) {
    guard let taskID = payload["taskId"].text else { return }
    let event = payload["event"]
    if ["shipios_subagent_event", "shipios_subagent_approval_state", "shipios_subagent_elicitation_state"].contains(event["type"].text ?? "") {
      guard activeThreads.contains(taskID) else { return }
      onSubagentEvent?(taskID, payload["threadId"].text, event)
      return
    }
    if event["type"].text == "shipios_subagent_snapshot" {
      guard activeThreads.contains(taskID) else { return }
      onSubagentSnapshot?(taskID, payload["threadId"].text, event)
      return
    }
    if ["task_started", "turn_started", "exec_command_begin", "exec_command_end",
      "exec_command_output_delta", "raw_response_item", "shutdown_complete"].contains(event["type"].text ?? "") {
      onRuntimeCommandEvent?(taskID, payload["threadId"].text, event)
    }
    if event["type"].text == "browser_request" {
      guard let token = browserTurnTokens[taskID], let stream = streams[taskID] else { return }
      stream.yield(event)
      onBrowserRequest?(taskID, token, event)
      return
    }
    if ["hook_started", "hook_completed"].contains(event["type"].text ?? "") {
      onHookEvent?(taskID, payload["threadId"].text, event)
      guard let continuation = streams[taskID], let threadID = payload["threadId"].text,
        case .object(var fields) = event else { return }
      fields["shipios_hook_thread_id"] = .string(threadID)
      continuation.yield(.object(fields))
      return
    }
    guard let continuation = streams[taskID] else { return }
    if ["task_complete", "turn_aborted"].contains(event["type"].text ?? ""),
      let eventTurnID = event["turn_id"].text,
      let activeTurnID = activeTurnIDs[taskID], eventTurnID != activeTurnID {
      return
    }
    if event["type"].text == "item_started", event["item"]["type"].text == "AgentMessage",
      let id = event["item"]["id"].text {
      nativeMessages[taskID]?.attempts[id] = ""
    }
    if event["type"].text == "agent_message_content_delta",
      let id = event["item_id"].text, let delta = event["delta"].text,
      var cursor = nativeMessages[taskID], case .object(var fields) = event {
      // Core replays an item's prefix when reconnecting. Publish its new
      // suffix once, while retaining already displayed text on failure.
      let candidate = (cursor.attempts[id] ?? "") + delta
      let previous = cursor.published[id] ?? ""
      cursor.attempts[id] = candidate
      if previous.hasPrefix(candidate) {
        nativeMessages[taskID] = cursor
        return
      }
      let suffix = candidate.hasPrefix(previous) ? String(candidate.dropFirst(previous.count)) : delta
      cursor.published[id] = candidate
      nativeMessages[taskID] = cursor
      // Keep all existing text consumers on the same transport contract.
      fields["type"] = .string("agent_message_delta")
      fields["delta"] = .string(suffix)
      fields["shipios_message_text"] = .string(candidate)
      continuation.yield(.object(fields))
    } else {
      continuation.yield(event)
    }
    switch event["type"].text {
    case "task_complete", "turn_aborted", "error":
      activeTurnIDs.removeValue(forKey: taskID)
      turnTokens.removeValue(forKey: taskID)
      browserTurnTokens.removeValue(forKey: taskID)
      streams.removeValue(forKey: taskID)?.finish()
      nativeMessages.removeValue(forKey: taskID)
    default: break
    }
  }
}
