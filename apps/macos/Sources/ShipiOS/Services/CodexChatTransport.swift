import Foundation
import CryptoKit

/// Routes Codex turns through independent, project-owned Agent processes.
@MainActor
final class CodexChatTransport {
  var onBrowserRequest: ((String, UUID, JSONValue) -> Void)?
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
  private var generation = UUID()
  private var activeThreads: Set<String> = []
  private var serviceIdentities: [String: ServiceIdentity] = [:]
  private var preparingTasks: Set<String> = []
  private var streams: [String: AsyncThrowingStream<JSONValue, Error>.Continuation] = [:]
  private var activeTurnIDs: [String: String] = [:]
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
    client.onCodexEvent = { [weak self] event in self?.receive(event) }
    client.onCodexGap = { [weak self] in
      self?.reset(project: path,
        error: AgentFailure(message: "Codex 事件流中断，本轮回复无法完整确认。"))
    }
    client.onDisconnect = { [weak self] message in
      self?.reset(project: path, error: AgentFailure(message: message))
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
    compact: Bool = false, forkOrigin: CodexForkOrigin? = nil,
    resumeOrigin: CodexResumeOrigin? = nil
  ) async throws -> AsyncThrowingStream<JSONValue, Error> {
    try Task.checkCancellation()
    guard streams[taskID] == nil, preparingTasks.insert(taskID).inserted else {
      throw AgentFailure(message: "该任务已有 Codex 回合正在运行。")
    }
    defer { preparingTasks.remove(taskID) }
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
      activeThreads.remove(taskID)
      activeTurnIDs.removeValue(forKey: taskID)
      serviceIdentities.removeValue(forKey: taskID)
    }
    let staged = try fileAppendix.map(stageText)
    defer { if let staged { try? FileManager.default.removeItem(at: staged.url) } }
    let (stream, continuation) = AsyncThrowingStream<JSONValue, Error>.makeStream()
    streams[taskID] = continuation
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
          "resumeOnly": .bool(compact),
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
        if let threadID = thread["threadId"].text, UUID(uuidString: threadID) != nil {
          onThreadStarted?(taskID, threadID, thread["historyWorkspace"].text ?? path)
        }
        if compact && sendFullContext {
          throw AgentFailure(message: "Codex 会话记录已不可用，无法整理上下文。")
        }
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
      if Task.isCancelled { await interrupt(taskID: taskID) }
      browserTurnTokens.removeValue(forKey: taskID)
      streams.removeValue(forKey: taskID)?.finish(throwing: error)
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

  func interrupt(taskID: String) async {
    browserTurnTokens.removeValue(forKey: taskID)
    guard activeThreads.contains(taskID) else { return }
    _ = try? await client(for: taskID).request("codex.turn.interrupt", ["taskId": .string(taskID)])
  }

  func stop(taskID: String) async {
    browserTurnTokens.removeValue(forKey: taskID)
    guard activeThreads.contains(taskID) else { return }
    _ = try? await client(for: taskID).request("codex.thread.stop", ["taskId": .string(taskID)])
    activeThreads.remove(taskID)
    serviceIdentities.removeValue(forKey: taskID)
    activeTurnIDs.removeValue(forKey: taskID)
    streams.removeValue(forKey: taskID)?.finish()
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
    activeThreads.removeAll()
    serviceIdentities.removeAll()
    activeTurnIDs.removeAll()
    browserTurnTokens.removeAll()
    taskProjects.removeAll()
    let pending = Array(streams.values)
    streams.removeAll()
    for stream in pending { stream.finish(throwing: error) }
  }

  private func reset(project: String, error: Error) {
    if let client = clients.removeValue(forKey: project) {
      Task { await client.stop() }
    }
    for taskID in taskProjects.filter({ $0.value == project }).map(\.key) {
      taskProjects.removeValue(forKey: taskID)
      activeThreads.remove(taskID)
      serviceIdentities.removeValue(forKey: taskID)
      activeTurnIDs.removeValue(forKey: taskID)
      browserTurnTokens.removeValue(forKey: taskID)
      streams.removeValue(forKey: taskID)?.finish(throwing: error)
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
    for client in running { await client.stop() }
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
    continuation.yield(event)
    switch event["type"].text {
    case "task_complete", "turn_aborted", "error":
      activeTurnIDs.removeValue(forKey: taskID)
      browserTurnTokens.removeValue(forKey: taskID)
      streams.removeValue(forKey: taskID)?.finish()
    default: break
    }
  }
}
