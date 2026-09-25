import Foundation

extension WorkspaceStore {
  var reviewComments: [ReviewComment] { reviewComments(taskID: nil) }

  func reviewComments(taskID: String?) -> [ReviewComment] {
    library.reviewComments[reviewCommentKey(taskID)] ?? []
  }

  func beginReviewComment(_ anchor: ReviewAnchor, taskID: String? = nil) {
    let expectedProject: URL?
    if let taskID { expectedProject = workspaceTabProject(owner: taskID) }
    else { expectedProject = project }
    guard let expectedProject,
      GitBranchService.canonicalRoot(expectedProject).path == anchor.project else { return }
    let key = reviewCommentKey(taskID)
    if let existing = reviewComments(taskID: taskID).first(where: { $0.anchor == anchor }) {
      editReviewComment(existing.id, taskID: taskID)
    } else {
      library.reviewComments[key, default: []].append(ReviewComment(anchor: anchor))
      saveLibrary()
    }
  }
  func editReviewComment(_ id: UUID, taskID: String? = nil) {
    mutateReviewComment(id, taskID: taskID) {
      if $0.editingText == nil { $0.editingText = $0.body }
    }
  }
  func updateReviewComment(_ id: UUID, text: String, taskID: String? = nil) {
    mutateReviewComment(id, taskID: taskID) { $0.editingText = text }
  }
  func saveReviewComment(_ id: UUID, taskID: String? = nil) {
    mutateReviewComment(id, taskID: taskID) { comment in
      let body = (comment.editingText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !body.isEmpty else { return }
      comment.body = body
      comment.editingText = nil
    }
  }
  func cancelReviewComment(_ id: UUID, taskID: String? = nil) {
    if reviewComments(taskID: taskID).first(where: { $0.id == id })?.body.isEmpty == true {
      removeReviewComment(id, taskID: taskID)
    } else {
      mutateReviewComment(id, taskID: taskID) { $0.editingText = nil }
    }
  }
  func removeReviewComment(_ id: UUID, taskID: String? = nil) {
    library.reviewComments[reviewCommentKey(taskID)]?.removeAll { $0.id == id }
    saveLibrary()
  }
  private func mutateReviewComment(
    _ id: UUID, taskID: String?, _ change: (inout ReviewComment) -> Void
  ) {
    let key = reviewCommentKey(taskID)
    guard let index = library.reviewComments[key]?.firstIndex(where: { $0.id == id }) else {
      return
    }
    change(&library.reviewComments[key]![index])
    saveLibrary()
  }

  private func reviewCommentKey(_ taskID: String?) -> String { taskID ?? draftKey }

  func promptWithReviewComments(
    _ prompt: String, comments: [ReviewComment], project expectedProject: String? = nil
  ) throws -> String {
    guard !comments.isEmpty else { return prompt }
    let commentProject = expectedProject ?? project?.path
    guard comments.allSatisfy({ $0.anchor.project == commentProject }) else {
      throw AgentFailure(message: "审查评论与当前项目不匹配。")
    }
    guard comments.allSatisfy({ $0.editingText == nil && !$0.body.isEmpty }) else {
      throw AgentFailure(message: "请先保存或取消正在编辑的审查评论。")
    }
    guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentFailure(message: "请在输入框说明如何处理这些审查评论，然后发送。")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let context = String(decoding: try encoder.encode(comments), as: UTF8.self)
    return prompt + "\n\n审查评论（代码与行号是添加评论时的快照，修改前请核对当前文件）：\n" + context
  }
}
