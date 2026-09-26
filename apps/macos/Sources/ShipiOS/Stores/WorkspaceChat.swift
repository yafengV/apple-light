import Foundation

extension WorkspaceStore {
  func loadModelConfiguration() async {
    let url = dataRoot.appendingPathComponent("model.json")
    do {
      let loaded = try await Task.detached(priority: .userInitiated) { () -> ModelConfiguration? in
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ModelConfiguration.self, from: Data(contentsOf: url))
      }.value
      if let loaded { modelConfiguration = loaded }
    } catch { self.error = "无法读取模型配置：\(error.localizedDescription)" }
  }
  func saveModelConfiguration(_ config: ModelConfiguration) throws {
    try config.validateEndpoint()
    try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
    let url = dataRoot.appendingPathComponent("model.json")
    try JSONEncoder().encode(config).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    modelConfiguration = config
  }
  func restoreInterruptedChats() {
    let interrupted = Set(library.chatRuns.filter(\.isActive).map(\.id))
    library.chatRuns = library.chatRuns.map { run in
      guard run.isActive else { return run }
      var result = run.result
      if case .object(var fields) = result {
        if !run.toolExecutions.isEmpty {
          let records = run.toolExecutions.map { item in
            var item = item
            if item.status == .running || item.status == .awaitingApproval {
              item.status = .cancelled
              item.output = "应用已重启，本次调用未恢复；请确认服务器实际状态。"
            }
            return item
          }
          fields["tool_executions"] = try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(records))
        }
        if !run.codexQuestions.isEmpty {
          let questions = run.codexQuestions.map { item in
            var item = item
            if item.status == .awaiting { item.status = .cancelled }
            return item
          }
          fields["codex_questions"] = try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(questions))
        }
        result = .object(fields)
      }
      return AgentRun(
        id: run.id, kind: run.kind, project: run.project, status: "interrupted",
        createdAt: run.createdAt, updatedAt: Date().timeIntervalSince1970 * 1000,
        request: run.request, result: result)
    }
    for (taskID, var session) in library.goalSessions
    where session.lastRunID.map(interrupted.contains) == true {
      session.status = .paused
      library.goalSessions[taskID] = session
    }
    saveLibrary()
  }
  func startChat(
    _ prompt: String, taskID explicitTaskID: String? = nil, consumeDraft: Bool = false,
    images: [ImageAttachment] = [], files: [FileAttachment] = [],
    queuedMessageID: UUID? = nil, mode: ChatMode = .standard,
    review: ModelCodeReviewContext? = nil
  )
    async
  {
    let requestedTaskID = explicitTaskID ?? selectedTask?.id
    guard canStartChat(taskID: requestedTaskID) else { return }
    let goalDefinition = mode == .goal
      ? (requestedTaskID.flatMap { library.goalSessions[$0]?.definition } ?? pendingGoal)?.normalized
      : nil
    if mode == .goal, goalDefinition == nil {
      error = "请先定义目标和成功标准。"
      return
    }
    var prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    if prompt.isEmpty, let goalDefinition {
      prompt = "开始执行目标：\(goalDefinition.objective)"
    }
    guard !prompt.isEmpty || !images.isEmpty || !files.isEmpty else { return }
    busy = true
    defer { busy = false }
    do {
      let config = modelConfiguration(for: requestedTaskID)
      let usesCodex = config.apiProtocol == .codexResponses
      let initialModelSelection = requestedTaskID.flatMap { id in
        library.tasks.first(where: { $0.id == id })?.modelSelection
      }
      let tools = usesCodex || mode == .plan || review != nil ? [] : try availableMCPTools()
      try config.validateEndpoint()
      guard !config.model.isEmpty else { throw AgentFailure(message: "请在设置 → 模型与 API 中配置独立服务。") }
      guard personalizationLoaded else {
        throw AgentFailure(message: "个人指令尚未成功加载，请在设置 → 个性化中检查并重新加载。")
      }
      guard memoryError == nil else {
        throw AgentFailure(message: "记忆尚未成功加载，请在设置 → 记忆中检查并重新加载。")
      }
      let key = try ModelKeychain.read(account: config.credentialAccount)
      let taskID = requestedTaskID
      let taskProject = taskID.flatMap { id in library.tasks.first(where: { $0.id == id })?.project }
      if usesCodex {
        guard mode == .standard else {
          throw AgentFailure(message: "Codex Responses 当前支持普通会话与代码审查；计划和目标模式仍待接入。")
        }
        guard connected, let project, (taskProject ?? currentProjectKey) == project.path else {
          throw AgentFailure(message: "Codex Responses 当前仅支持已连接项目中的任务，请先打开对应项目。")
        }
      }
      let submittedTerminal = taskID == nil ? terminalScope : nil
      let branch = taskProject == nil || taskProject == currentProjectKey
        ? await branchForTaskHistory() : nil
      guard !shuttingDown, !Task.isCancelled else { return }
      let pluginContext = try PluginStorage.promptContext(
        prompt: prompt, preferences: activePluginPreferences, root: dataRoot)
      let runID = UUID().uuidString
      let effectiveProject = taskProject ?? currentProjectKey
      let projectlessOwner = taskID ?? runID
      let projectlessDirectory = effectiveProject.isEmpty
        ? try projectlessWorkspace(taskID: projectlessOwner, create: true) : nil
      let goalIteration = mode == .goal
        ? (taskID.flatMap { library.goalSessions[$0]?.iteration } ?? 0) + 1 : 0
      let modeInstructions: String
      switch mode {
      case .standard: modeInstructions = ""
      case .plan: modeInstructions = Self.planModeInstructions
      case .goal:
        modeInstructions = Self.goalModeInstructions(
          definition: goalDefinition!, iteration: goalIteration)
      }
      let workspaceInstructions = projectlessDirectory.map {
        "此任务没有项目目录。需要创建草稿、生成资源或引用输出文件时，只能使用此任务的独立文件夹：\($0.path)。回答中的相对文件链接也应以该文件夹为根目录。"
      } ?? ""
      let instructions = [
        systemInstructions, modeInstructions, review == nil ? "" : ModelCodeReviewContext.instructions,
        pluginContext.instructions, workspaceInstructions,
      ]
        .filter { !$0.isEmpty }.joined(separator: "\n\n")
      var messages = [ChatMessage(role: "system", content: instructions)]
      messages.append(contentsOf: library.chatContext(taskID: taskID))
      messages.append(
        ChatMessage(
          role: "user", content: review.map {
            usesCodex ? "\($0.snapshot.requestTitle)。审查此消息附带的只读 Git 差异。" : $0.snapshot.modelPrompt
          } ?? prompt,
          images: images, files: files))
      let now = Date().timeIntervalSince1970 * 1000
      var request: [String: JSONValue] = [
        "kind": .string("chat"), "model": .string(config.model),
        "mode": .string(mode.rawValue),
        "api_protocol": .string(config.apiProtocol.rawValue),
      ]
      if !config.reasoning.isEmpty { request["reasoning_effort"] = .string(config.reasoning) }
      if let review {
        request["conversation_kind"] = .string("review")
        request["review_scope"] = .string(review.snapshot.scope.metadataValue)
        request["review_delivery"] = .string(review.delivery.rawValue)
        request["review_diff_bytes"] = .number(Double(review.snapshot.diff.utf8.count))
        if let selection = review.snapshot.scope.selection {
          request["review_selection"] = .string(selection)
        }
      }
      if !pluginContext.ids.isEmpty {
        request["plugins"] = .array(pluginContext.ids.map(JSONValue.string))
      }
      if !pluginContext.skillIDs.isEmpty {
        request["skills"] = .array(pluginContext.skillIDs.map(JSONValue.string))
      }
      if let projectlessDirectory {
        request["workspace"] = .string(projectlessDirectory.path)
      }
      if let goalDefinition {
        request["goal_objective"] = .string(goalDefinition.objective)
        request["goal_success_criteria"] = .array(
          goalDefinition.successCriteria.map(JSONValue.string))
        request["goal_iteration"] = .number(Double(goalIteration))
        request["goal_max_iterations"] = .number(Double(goalDefinition.maxIterations))
      }
      let run = AgentRun(
        id: runID, kind: "chat", project: effectiveProject,
        status: "running",
        createdAt: now, updatedAt: now,
        request: .object(request),
        result: .object(["response": .string("")]))
      var candidate = library
      if let projectlessDirectory {
        candidate.projectlessTaskDirectories[projectlessOwner] = projectlessDirectory.path
      }
      if consumeDraft {
        let submittedDraftKey = taskID ?? draftKey
        candidate.draftImages[submittedDraftKey] = nil
        candidate.draftFiles[submittedDraftKey] = nil
        candidate.drafts[submittedDraftKey] = ""
      }
      if let queuedMessageID { candidate.queuedMessages.removeAll { $0.id == queuedMessageID } }
      candidate.runImages[run.id] = images
      candidate.runFiles[run.id] = files
      candidate.attach(run, to: taskID, note: prompt)
      if let owner = candidate.tasks.firstIndex(where: { $0.runIDs.contains(run.id) }),
        candidate.tasks[owner].modelSelection == initialModelSelection {
        candidate.tasks[owner].modelSelection = TaskModelSelection(model: config.model, reasoning: config.reasoning,
          providerAccount: config.credentialAccount, apiProtocol: config.apiProtocol)
      }
      if let goalDefinition, let owner = candidate.task(containing: run.id) {
        var session = candidate.goalSessions[owner.id] ?? GoalSession(definition: goalDefinition)
        session.definition = goalDefinition
        session.status = .active
        session.iteration = goalIteration
        session.lastRunID = run.id
        candidate.goalSessions[owner.id] = session
      }
      if let branch { candidate.runBranches[run.id] = branch }
      if prompt.isEmpty, taskID == nil, let index = candidate.tasks.firstIndex(where: { $0.id == run.id }) {
        candidate.tasks[index].title = files.first?.name ?? images.first?.name ?? "附件会话"
      }
      candidate.chatRuns.append(run)
      if explicitTaskID == nil || selectedTask?.id == taskID {
        candidate.projectSelections[currentProjectKey] = run.id
        candidate.lastWorkspace = currentProjectKey
      }
      if let review { try ReviewSnapshotStorage.save(review.snapshot, runID: run.id, root: dataRoot) }
      do { try commitLibrary(candidate) }
      catch {
        if review != nil { ReviewSnapshotStorage.remove(runID: run.id, root: dataRoot) }
        throw error
      }
      if mode == .goal { pendingGoal = nil }
      adoptDraftTerminal(submittedTerminal, run: run)
      completionTracker.begin(run.id)
      runs.insert(run, at: 0)
      if explicitTaskID == nil || selectedTask?.id == taskID { selection = run.id }
      error = nil
      let requestTask = Task { [weak self] in
        guard let self else { return }
        do {
          let usage: ModelTokenUsage?
          if usesCodex {
            usage = try await streamCodexChat(runID: run.id,
              taskID: review == nil ? (taskID ?? run.id) : run.id,
              config: config, key: key, messages: messages, review: review)
          } else {
            usage = try await streamChatWithTools(runID: run.id, config: config, key: key,
              messages: messages, bindings: tools)
          }
          let continueGoal = finishChat(run.id, status: "succeeded", usage: usage)
          removeModelTask(runID: run.id)
          if let owner = library.task(containing: run.id),
            !library.queuedMessages.contains(where: {
              $0.taskID == owner.id && self.codexSteeringMessages.contains($0.id)
            }),
            let next = library.queuedMessages.first(where: { $0.taskID == owner.id }),
            canStartChat(taskID: owner.id)
          {
            await sendQueuedMessage(next)
          } else if let continueGoal, canStartChat(taskID: continueGoal) {
            await startChat(
              GoalResponseParser.continuationPrompt, taskID: continueGoal, mode: .goal)
          }
        } catch {
          let cancelled = Task.isCancelled || error is CancellationError
          _ = finishChat(
            run.id, status: cancelled ? "cancelled" : "failed",
            message: cancelled ? nil : error.localizedDescription)
          removeModelTask(runID: run.id)
        }
      }
      installModelTask(requestTask, runID: run.id)
    } catch { self.error = error.localizedDescription }
  }
  func appendChat(_ id: String, delta: String) {
    guard let current = library.chatRuns.first(where: { $0.id == id }) else { return }
    var items = current.responseItems
    if items == nil, current.request["api_protocol"].text == ModelAPIProtocol.codexResponses.rawValue {
      items = []
    }
    if var existing = items {
      ChatResponseItem.append(delta, to: &existing)
      items = existing
    }
    replaceChat(
      current, status: current.status, response: (current.result?["response"].text ?? "") + delta,
      responseItems: items)
    if Date().timeIntervalSince(lastChatSave) > 1 {
      lastChatSave = Date()
      saveLibrary()
    }
  }
  private func streamCodexChat(
    runID: String, taskID: String, config: ModelConfiguration, key: String?, messages: [ChatMessage],
    review: ModelCodeReviewContext?
  ) async throws -> ModelTokenUsage? {
    let initialText = messages.map { "[\($0.role)]\n\($0.content)" }.joined(separator: "\n\n")
    let images = messages.last?.images ?? []
    for image in images { _ = try ImageAttachmentStorage.data(image, root: dataRoot) }
    let files = messages.last?.files ?? []
    var fileTextBytes = 0
    let fileAppendix = files.isEmpty ? nil : try FileAttachmentStorage.content(
      ChatMessage(role: "user", content: "", files: files), root: dataRoot,
      total: &fileTextBytes)
    let reviewAppendix = review.map { "\n\n\($0.snapshot.modelPrompt)" }
    guard let continuationText = messages.last?.content,
      !continuationText.isEmpty || !images.isEmpty || !files.isEmpty else {
      throw AgentFailure(message: "Codex 回合缺少输入。")
    }
    let stream = try await codexTransport.startTurn(
      taskID: taskID, config: config, key: key,
      initialText: initialText, continuationText: continuationText, images: images,
      fileAppendix: reviewAppendix ?? fileAppendix, readOnly: review != nil)
    do {
      let usage: ModelTokenUsage? = try await withTaskCancellationHandler {
      var rendered = ""
      var completed = false
      do {
        for try await event in stream {
          try Task.checkCancellation()
          switch event["type"].text {
          case "exec_command_begin", "exec_command_end", "patch_apply_begin", "patch_apply_end":
            if event["type"].text?.hasSuffix("_begin") == true {
              recordCodexRuntimeStatus(runID: runID, message: nil)
            }
            recordCodexCommand(runID: runID, event: event)
            if event["type"].text == "exec_command_begin" || event["type"].text == "patch_apply_begin" {
              rendered = ""
            }
          case "exec_approval_request", "apply_patch_approval_request":
            try await resolveCodexApproval(runID: runID, taskID: taskID, event: event,
              readOnlyReview: review != nil)
          case "request_user_input":
            try await handleCodexQuestion(runID: runID, taskID: taskID, event: event)
          case "plan_update":
            recordCodexRuntimeStatus(runID: runID, message: nil)
            try recordCodexPlan(runID: runID, event: event)
          case "stream_error", "stream_info", "auth_recovery_started", "auth_recovery_completed":
            recordCodexRuntimeStatus(runID: runID,
              message: event["message"].text ?? "Codex 正在恢复连接…")
          case "agent_message_delta":
            if let delta = event["delta"].text, !delta.isEmpty {
              recordCodexRuntimeStatus(runID: runID, message: nil)
              appendChat(runID, delta: delta)
              rendered += delta
            }
          case "agent_message":
            if let message = event["message"].text, !message.isEmpty {
              recordCodexRuntimeStatus(runID: runID, message: nil)
              if message.hasPrefix(rendered) {
                let suffix = String(message.dropFirst(rendered.count))
                if !suffix.isEmpty { appendChat(runID, delta: suffix) }
              } else if let current = library.chatRuns.first(where: { $0.id == runID }) {
                var items = current.responseItems ?? []
                items.append(.message(id: UUID(), text: message))
                replaceChat(current, status: current.status,
                  response: (current.result?["response"].text ?? "") + message,
                  responseItems: items)
              }
              rendered = message
            }
          case "task_complete":
            recordCodexRuntimeStatus(runID: runID, message: nil)
            expireCodexQuestions(runID: runID)
            if library.chatRuns.first(where: { $0.id == runID })?.result?["response"].text?.isEmpty != false,
              let message = event["last_agent_message"].text,
              !message.isEmpty { appendChat(runID, delta: message) }
            if let message = event["error"]["message"].text, !message.isEmpty {
              throw AgentFailure(message: message)
            }
            completed = true
          case "turn_aborted":
            let reason = event["reason"].text ?? "interrupted"
            if reason == "budget_limited" {
              throw AgentFailure(message: "Codex 回合因预算限制而停止，已保留收到的内容。")
            }
            throw CancellationError()
          case "error":
            throw AgentFailure(message: event["message"].text ?? "Codex 回合失败。")
          default: break
          }
        }
        guard completed else { throw AgentFailure(message: "Codex 事件流提前结束，已保留收到的内容。") }
        return nil
      } catch {
        await codexTransport.interrupt(taskID: taskID)
        throw error
      }
      } onCancel: {
        Task { @MainActor [weak self] in await self?.codexTransport.interrupt(taskID: taskID) }
      }
      if review != nil { await codexTransport.stop(taskID: taskID) }
      return usage
    } catch {
      if review != nil { await codexTransport.stop(taskID: taskID) }
      throw error
    }
  }
  private func recordCodexRuntimeStatus(runID: String, message: String?) {
    guard let current = library.chatRuns.first(where: { $0.id == runID }) else { return }
    let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)
    let value = trimmed.map { String($0.prefix(500)) }.flatMap { $0.isEmpty ? nil : $0 }
    guard current.result?["codex_runtime_status"].text != value else { return }
    var fields: [String: JSONValue] = [:]
    if case .object(let existing) = current.result { fields = existing }
    fields["codex_runtime_status"] = value.map(JSONValue.string) ?? .null
    let updated = AgentRun(id: current.id, kind: current.kind, project: current.project,
      status: current.status, createdAt: current.createdAt,
      updatedAt: Date().timeIntervalSince1970 * 1000,
      request: current.request, result: .object(fields))
    if let index = library.chatRuns.firstIndex(where: { $0.id == runID }) {
      library.chatRuns[index] = updated
    }
    if let index = runs.firstIndex(where: { $0.id == runID }) { runs[index] = updated }
    saveLibrary()
  }
  @discardableResult private func recordCodexCommand(runID: String, event: JSONValue) -> MCPToolExecution? {
    guard let current = library.chatRuns.first(where: { $0.id == runID }) else { return nil }
    var executions = current.toolExecutions
    var items = current.responseItems ?? []
    guard CodexCommandTimeline.apply(event, executions: &executions, items: &items) else { return nil }
    replaceChat(current, status: current.status, response: current.result?["response"].text ?? "",
      responseItems: items, toolExecutions: executions)
    saveLibrary()
    let patch = event["type"].text?.contains("patch") == true
    return executions.first {
      $0.serverID == CodexCommandTimeline.serverID && $0.callID == event["call_id"].text
        && $0.toolName == (patch ? "补丁" : "命令")
    }
  }
  private func recordCodexPlan(runID: String, event: JSONValue) throws {
    guard let current = library.chatRuns.first(where: { $0.id == runID }) else { return }
    let plan = try CodexPlan.update(event, existing: current.codexPlan)
    var items = current.responseItems ?? []
    if current.codexPlan == nil { items.append(.plan(plan.id)) }
    replaceChat(current, status: current.status, response: current.result?["response"].text ?? "",
      responseItems: items, codexPlan: plan)
    saveLibrary()
  }
  private func resolveCodexApproval(runID: String, taskID: String, event: JSONValue,
    readOnlyReview: Bool = false) async throws {
    guard let callID = event["call_id"].text,
      let execution = recordCodexCommand(runID: runID, event: event) else {
      throw AgentFailure(message: "Codex 审批事件缺少工具标识。")
    }
    let patch = event["type"].text == "apply_patch_approval_request"
    let choices = patch ? (once: true, task: false) : CodexCommandTimeline.approvalChoices(event)
    let decision: MCPApprovalDecision = readOnlyReview ? .deny
      : await requestMCPApproval(execution, runID: runID,
        allowsOnce: choices.once, allowsTask: choices.task)
    try Task.checkCancellation()
    let allowed = decision != .deny
    let id = patch ? callID : (event["approval_id"].text ?? callID)
    try await codexTransport.approve(taskID: taskID, id: id,
      turnID: patch ? nil : event["turn_id"].text, patch: patch, decision: decision)
    if let current = library.chatRuns.first(where: { $0.id == runID }) {
      var executions = current.toolExecutions
      CodexCommandTimeline.resolve(callID: callID, patch: patch, allowed: allowed,
        executions: &executions)
      if readOnlyReview, let index = executions.firstIndex(where: {
        $0.callID == callID && $0.serverID == CodexCommandTimeline.serverID
      }) {
        executions[index].output = "代码审查为只读，已拒绝写入操作。"
      }
      replaceChat(current, status: current.status, response: current.result?["response"].text ?? "",
        toolExecutions: executions)
      saveLibrary()
    }
  }
  private func finishChat(
    _ id: String, status: String, message: String? = nil, usage: ModelTokenUsage? = nil
  ) -> String? {
    expireCodexQuestions(runID: id)
    guard let current = library.chatRuns.first(where: { $0.id == id }) else { return nil }
    var response = current.result?["response"].text ?? ""
    var items = current.responseItems
    var continueTaskID: String?
    if current.request["mode"].text == ChatMode.goal.rawValue,
      let owner = library.task(containing: id), var session = library.goalSessions[owner.id]
    {
      let parsed = GoalResponseParser.parse(response)
      response = parsed.text
      if let last = items?.indices.last, case .message(let itemID, let text) = items?[last] {
        items?[last] = .message(id: itemID, text: GoalResponseParser.parse(text).text)
      }
      session.lastRunID = id
      if session.status != .active {
        continueTaskID = nil
      } else if status == "succeeded" {
        switch parsed.signal {
        case .complete: session.status = .completed
        case .continueWorking where session.iteration < session.definition.maxIterations:
          session.status = .active
          continueTaskID = owner.id
        case .continueWorking, .none: session.status = .paused
        }
      } else {
        session.status = .paused
      }
      library.goalSessions[owner.id] = session
      if selectedTask?.id == owner.id, session.status != .active { chatMode = .standard }
    }
    replaceChat(
      current, status: status, response: response, message: message,
      usage: usage, responseItems: items)
    saveLibrary()
    if let finished = runs.first(where: { $0.id == id }) { observeCompletions([finished]) }
    return continueTaskID
  }
  func replaceChat(
    _ current: AgentRun, status: String, response: String, message: String? = nil,
    usage: ModelTokenUsage? = nil, responseItems: [ChatResponseItem]? = nil,
    toolExecutions: [MCPToolExecution]? = nil,
    codexQuestions: [CodexQuestionRequest]? = nil, codexPlan: CodexPlan? = nil
  ) {
    var result: [String: JSONValue] = [:]
    if case .object(let fields) = current.result { result = fields }
    result["response"] = .string(response)
    if let responseItems, let value = try? ChatResponseItem.json(responseItems) {
      result["response_items"] = value
    }
    if let toolExecutions,
      let value = try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(toolExecutions)) {
      result["tool_executions"] = value
    }
    if let codexQuestions,
      let value = try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(codexQuestions)) {
      result["codex_questions"] = value
    }
    if let codexPlan,
      let value = try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(codexPlan)) {
      result["codex_plan"] = value
    }
    if let message { result["message"] = .string(message) }
    if let usage { result["usage"] = usage.jsonValue }
    else if current.result?["usage"] != .null { result["usage"] = current.result?["usage"] }
    let run = AgentRun(
      id: current.id, kind: current.kind, project: current.project, status: status,
      createdAt: current.createdAt,
      updatedAt: Date().timeIntervalSince1970 * 1000, request: current.request,
      result: .object(result))
    if let i = runs.firstIndex(where: { $0.id == run.id }) { runs[i] = run }
    if let i = library.chatRuns.firstIndex(where: { $0.id == run.id }) { library.chatRuns[i] = run }
  }
  func sendQueuedMessage(_ message: QueuedMessage) async {
    guard canStartChat(taskID: message.taskID), library.queuedMessages.contains(message),
      library.tasks.contains(where: { $0.id == message.taskID })
    else { return }
    let mode = library.goalSessions[message.taskID]?.status == .active ? .goal : message.mode
    await startChat(
      message.text, taskID: message.taskID, images: message.images, files: message.files,
      queuedMessageID: message.id, mode: mode)
  }
  func steerActiveChat(with message: QueuedMessage) async {
    guard library.queuedMessages.contains(message) else { return }
    guard let active = activeChatRun(taskID: message.taskID) else {
      await sendQueuedMessage(message)
      return
    }
    if active.request["api_protocol"].text == ModelAPIProtocol.codexResponses.rawValue,
      message.mode == .standard {
      guard codexSteeringMessages.insert(message.id).inserted else { return }
      do {
        for image in message.images { _ = try ImageAttachmentStorage.data(image, root: dataRoot) }
        var fileTextBytes = 0
        let fileAppendix = message.files.isEmpty ? nil : try FileAttachmentStorage.content(
          ChatMessage(role: "user", content: "", files: message.files), root: dataRoot,
          total: &fileTextBytes)
        let steered = try await codexTransport.steer(taskID: message.taskID,
          text: message.text, images: message.images, fileAppendix: fileAppendix)
        codexSteeringMessages.remove(message.id)
        if steered { try recordCodexSteeredMessage(message, runID: active.id) }
        if activeChatRun(taskID: message.taskID) == nil,
          let next = library.queuedMessages.first(where: { $0.taskID == message.taskID }) {
          await sendQueuedMessage(next)
        }
      } catch {
        codexSteeringMessages.remove(message.id)
        self.error = error.localizedDescription
      }
      return
    }
    let running = modelTask(runID: active.id)
    running?.cancel()
    await running?.value
    guard library.queuedMessages.contains(message) else { return }
    await sendQueuedMessage(message)
  }
  private func recordCodexSteeredMessage(_ message: QueuedMessage, runID: String) throws {
    guard let index = library.chatRuns.firstIndex(where: { $0.id == runID }) else {
      throw AgentFailure(message: "Codex 会话记录已不存在，追加消息未保存。")
    }
    let current = library.chatRuns[index]
    var fields: [String: JSONValue] = [:]
    if case .object(let value) = current.result { fields = value }
    let messages = current.codexSteeredMessages + [message]
    var items = current.responseItems ?? []
    items.append(.user(message.id))
    fields["codex_steered_messages"] = try JSONDecoder().decode(JSONValue.self,
      from: JSONEncoder().encode(messages))
    fields["response_items"] = try ChatResponseItem.json(items)
    let updated = AgentRun(id: current.id, kind: current.kind, project: current.project,
      status: current.status, createdAt: current.createdAt,
      updatedAt: Date().timeIntervalSince1970 * 1000,
      request: current.request, result: .object(fields))
    var candidate = library
    candidate.chatRuns[index] = updated
    candidate.queuedMessages.removeAll { $0.id == message.id }
    try commitLibrary(candidate)
    if let displayIndex = runs.firstIndex(where: { $0.id == runID }) {
      runs[displayIndex] = updated
    }
  }
  func removeQueuedMessage(_ id: UUID) {
    guard !codexSteeringMessages.contains(id) else { return }
    do {
      var candidate = library
      candidate.queuedMessages.removeAll { $0.id == id }
      try commitLibrary(candidate)
    } catch { self.error = error.localizedDescription }
  }
  func editQueuedMessage(_ message: QueuedMessage) {
    guard !codexSteeringMessages.contains(message.id) else { return }
    guard selectedTask?.id == message.taskID else { return }
    guard draft.isEmpty, draftImages.isEmpty, draftFiles.isEmpty, !importingImages, !importingFiles else {
      error = "请先发送或清空现有草稿，再编辑队列消息。"
      return
    }
    do {
      var candidate = library
      candidate.draftImages[draftKey] = message.images
      candidate.draftFiles[draftKey] = message.files
      candidate.drafts[draftKey] = message.text
      candidate.queuedMessages.removeAll { $0.id == message.id }
      try commitLibrary(candidate)
      action = .chat
      chatMode = message.mode
      focusComposer = UUID()
    } catch { self.error = error.localizedDescription }
  }
  func moveQueuedMessage(_ message: QueuedMessage, offset: Int) {
    guard !codexSteeringMessages.contains(message.id) else { return }
    let ids = library.queuedMessages.filter { $0.taskID == message.taskID }.map(\.id)
    guard let i = ids.firstIndex(of: message.id), ids.indices.contains(i + offset),
      let a = library.queuedMessages.firstIndex(where: { $0.id == message.id }),
      let b = library.queuedMessages.firstIndex(where: { $0.id == ids[i + offset] })
    else { return }
    library.queuedMessages.swapAt(a, b)
    saveLibrary()
  }
  func handleComposerCommand() -> Bool {
    let command = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    if command == "/review" {
      guard commandEnabled("review") else {
        error = "当前无法执行此操作，请先打开项目或返回任务页面。"
        return true
      }
      draft = ""
      presentCodeReviewMode()
      return true
    }
    if command == "/fork" {
      forkConversation(consumeCommand: true)
      return true
    }
    if command == "/plan" {
      if chatMode == .goal { leaveGoalMode() }
      action = .chat
      chatMode = .plan
      draft = ""
      focusComposer = UUID()
      return true
    }
    if command == "/goal" {
      action = .chat
      draft = ""
      showingGoalEditor = true
      return true
    }
    if command.hasPrefix("/plan"), command.count > 5,
      command[command.index(command.startIndex, offsetBy: 5)].isWhitespace
    {
      if chatMode == .goal { leaveGoalMode() }
      action = .chat
      chatMode = .plan
      draft = String(command.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
      return false
    }
    let actions = [
      "/project": "projects", "/new": "new", "/files": "files",
      "/terminal": "terminal", "/pet": "pet", "/plugins": "plugins",
      "/automations": "automations",
      "/model": "model", "/reasoning": "model",
    ]
    if let action = actions[command] {
      guard commandEnabled(action) else {
        error = "当前无法执行此操作，请先打开项目或返回任务页面。"
        return true
      }
      draft = ""
      executeCommand(action)
      return true
    }
    return false
  }

  func continueFromPlan(_ run: AgentRun) {
    guard run.kind == "chat", run.request["mode"].text == ChatMode.plan.rawValue,
      run.status == "succeeded", selectedTask?.runIDs.contains(run.id) == true
    else { return }
    guard draft.isEmpty, draftImages.isEmpty, draftFiles.isEmpty, !importingImages, !importingFiles else {
      error = "请先发送或清空当前草稿，再按计划继续。"
      return
    }
    action = .chat
    chatMode = .standard
    draft = "按照上面的计划开始实现。完成后运行相关验证并报告结果。"
    focusComposer = UUID()
  }

  private static let planModeInstructions = """
    当前回合处于计划模式。分析用户目标和已有会话上下文，给出可执行的实施计划。计划应列出有序步骤、关键文件或系统边界、验证方法、必要假设和主要风险。不要声称已经执行、修改或验证任何尚未完成的工作。
    """

  private static func goalModeInstructions(
    definition: GoalDefinition, iteration: Int
  ) -> String {
    let criteria = definition.successCriteria.enumerated().map { "\($0.offset + 1). \($0.element)" }
      .joined(separator: "\n")
    return """
      当前任务处于目标模式。持续推进目标，主动完成必要工作与验证，不要在仍可独立推进时停在建议或计划上。

      目标：
      \(definition.objective)

      成功标准：
      \(criteria)

      当前为第 \(iteration) 轮，最多 \(definition.maxIterations) 轮。根据现有上下文检查每条成功标准。回复最后必须单独输出且只输出以下状态行之一：
      SHIPIOS_GOAL_STATUS: continue
      SHIPIOS_GOAL_STATUS: complete

      只有在所有成功标准均有可核验依据时使用 complete；否则使用 continue。状态行会由客户端移除。
      """
  }
}
