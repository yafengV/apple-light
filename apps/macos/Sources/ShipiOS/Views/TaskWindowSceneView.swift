import SwiftUI

/// Window-owned history survives task navigation; task-owned panels are recreated.
struct TaskWindowSceneView: View {
  @Bindable var store: WorkspaceStore
  @Binding var route: TaskWindowRoute?
  @State private var renameHistory = TaskRenameHistory()
  @State private var navigation = TaskWindowNavigation()

  private var availableTasks: Set<String> { Set(store.library.tasks.map(\.id)) }

  var body: some View {
    if let route {
      TaskWindowView(store: store, taskID: route.taskID, renameHistory: renameHistory,
        onNavigate: visit,
        canGoBack: navigation.destination(backwards: true, current: route.taskID, available: availableTasks) != nil,
        canGoForward: navigation.destination(backwards: false, current: route.taskID, available: availableTasks) != nil,
        onMove: move)
        .id(route.taskID)
    }
  }

  private func visit(_ taskID: String) {
    guard let route, navigation.visit(taskID, from: route.taskID, available: availableTasks) else { return }
    self.route = TaskWindowRoute(taskID: taskID)
  }

  private func move(_ backwards: Bool) {
    guard let route,
      let next = navigation.move(backwards: backwards, current: route.taskID, available: availableTasks) else { return }
    self.route = TaskWindowRoute(taskID: next)
  }
}
