import SwiftUI

/// Window-owned history survives task navigation; task-owned panels are recreated.
struct TaskWindowSceneView: View {
  @Bindable var store: WorkspaceStore
  @Binding var route: TaskWindowRoute?
  @State private var renameHistory = TaskRenameHistory()

  var body: some View {
    if let route {
      TaskWindowView(store: store, taskID: route.taskID, renameHistory: renameHistory,
        onNavigate: { self.route = TaskWindowRoute(taskID: $0) })
        .id(route.taskID)
    }
  }
}
