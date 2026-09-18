import Foundation

extension DeveloperWorkspace {
  func generateCommitMessage(config: ModelConfiguration, key: String?, instructions: String,
    includeUnstaged: Bool = false) {
    guard let root, canCommit, !gitBusy, !reviewScope.isHistorical, !generatingCommitMessage else { return }
    let token = UUID(), originalMessage = commitMessage
    commitGenerationToken = token
    generatingCommitMessage = true
    commitGenerationError = nil
    commitGenerationTask = Task { [weak self] in
      guard let self else { return }
      defer {
        if commitGenerationToken == token {
          generatingCommitMessage = false
          commitGenerationToken = nil
          commitGenerationTask = nil
        }
      }
      do {
        let context = try await GitCommitContext.capture(at: root, includeUnstaged: includeUnstaged)
        try Task.checkCancellation()
        let result = try await ModelAPIClient().streamTurn(config: config, key: key,
          messages: context.messages(instructions: instructions), onDelta: { _ in })
        try Task.checkCancellation()
        guard result.calls.isEmpty else { throw AgentFailure(message: "提交说明生成返回了意外的工具请求。") }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 16_384 else {
          throw AgentFailure(message: "模型未返回有效的提交说明，请重试。")
        }
        guard try await GitCommitContext.capture(at: root, includeUnstaged: includeUnstaged) == context else {
          throw AgentFailure(message: "暂存内容或分支已改变，请重新生成提交说明。")
        }
        try Task.checkCancellation()
        guard commitGenerationToken == token, self.root == root else { return }
        guard commitMessage == originalMessage else {
          throw AgentFailure(message: "提交说明已手动修改，未替换当前内容。")
        }
        commitMessage = text
      } catch {
        if !Task.isCancelled, commitGenerationToken == token, self.root == root {
          commitGenerationError = error.localizedDescription
        }
      }
    }
  }

  func cancelCommitMessageGeneration() {
    commitGenerationTask?.cancel()
    commitGenerationTask = nil
    commitGenerationToken = nil
    generatingCommitMessage = false
  }
}
