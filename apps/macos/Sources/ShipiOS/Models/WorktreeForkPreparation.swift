import Foundation
import Observation

/// The operation owns creation; a window only owns whether its preparation page is selected.
@MainActor @Observable final class WorktreeForkPreparation: Identifiable {
  enum State: Equatable { case preparing, cancelled, failed(String), ready }
  let id = UUID()
  let sourceTaskID: String
  let title: String
  var taskID: String?
  var path: String?
  var phase = "正在检查仓库和项目环境…"
  var state: State = .preparing
  @ObservationIgnored var operation: Task<WorkspaceTask?, Never>?
  @ObservationIgnored let notices: WorkspaceNotices
  @ObservationIgnored private var completed = false
  @ObservationIgnored private var result: WorkspaceTask?
  @ObservationIgnored private var waiters: [CheckedContinuation<WorkspaceTask?, Never>] = []

  init(sourceTaskID: String, title: String, taskID: String? = nil, path: String? = nil,
    notices: WorkspaceNotices) {
    self.sourceTaskID = sourceTaskID; self.title = title
    self.taskID = taskID; self.path = path; self.notices = notices
  }

  func cancel() {
    guard state == .preparing else { return }
    phase = "正在取消…"
    operation?.cancel()
  }

  func value() async -> WorkspaceTask? {
    if completed { return result }
    return await withCheckedContinuation { waiters.append($0) }
  }
  func finish(_ result: WorkspaceTask?) {
    self.result = result; completed = true
    let pending = waiters; waiters.removeAll()
    for waiter in pending { waiter.resume(returning: result) }
  }
}

/// Keep this at the scene/resource owner, so hiding the source view never cancels creation.
@MainActor @Observable final class WorktreeForkPresentation {
  private(set) var preparation: WorktreeForkPreparation?
  @ObservationIgnored var onReady: ((WorkspaceTask) async -> Void)?
  func present(_ preparation: WorktreeForkPreparation) { self.preparation = preparation }
  func owns(_ preparation: WorktreeForkPreparation) -> Bool { self.preparation === preparation }
  func dismiss() { preparation = nil }
  func close() { preparation?.cancel(); dismiss(); onReady = nil }
}
