import SwiftUI

private struct TaskRenameUndoScope: ViewModifier {
  let store: WorkspaceStore
  let history: TaskRenameHistory
  let blocked: Bool
  let revealInMain: Bool
  let onReveal: ((String) -> Void)?
  @State private var routing = TaskRenameUndoRouting()
  func body(content: Content) -> some View {
    let commands = routing.context(history: history, store: store, blocked: blocked, revealInMain: revealInMain, onReveal: onReveal)
    content
      .focusedSceneValue(\.taskRenameUndo, commands)
      .background(TaskRenameUndoBridge(routing: routing, context: commands).frame(width: 0, height: 0))
      .overlay(alignment: .bottom) {
        if let message = history.message {
          HStack {
            Image(systemName: history.failed ? "exclamationmark.circle" : "checkmark.circle")
            Text(message).textSelection(.enabled)
            Button { history.message = nil } label: { Image(systemName: "xmark") }
              .buttonStyle(.plain).accessibilityLabel("关闭重命名反馈")
          }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(20).accessibilityElement(children: .contain)
        }
      }
      .task(id: history.nextExpiration) {
        guard let deadline = history.nextExpiration else { return }
        try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
        guard !Task.isCancelled else { return }
        history.expire()
      }
      .task(id: history.message) {
        guard history.message != nil, !history.failed else { return }
        try? await Task.sleep(for: .seconds(5))
        guard !Task.isCancelled else { return }
        history.message = nil
      }
  }
}

extension View {
  func taskRenameUndo(store: WorkspaceStore, history: TaskRenameHistory, blocked: Bool, revealInMain: Bool = false, onReveal: ((String) -> Void)? = nil) -> some View {
    modifier(TaskRenameUndoScope(store: store, history: history, blocked: blocked, revealInMain: revealInMain, onReveal: onReveal))
  }
}
