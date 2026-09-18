import SwiftUI
import OSLog

/// Window-owned history survives task navigation; task-owned panels are recreated.
struct TaskWindowSceneView: View {
  private static let logger = Logger(subsystem: "dev.shipios.desktop", category: "WindowRestoration")
  @Bindable var store: WorkspaceStore
  @Binding var route: TaskWindowRoute?
  @State private var renameHistory = TaskRenameHistory()
  @State private var browsers = TaskWindowBrowsers()
  @State private var navigation = TaskWindowNavigation()
  @State private var hasPresentedTask = false
  @Environment(\.dismiss) private var dismiss

  private var availableTasks: Set<String> { Set(store.library.tasks.map(\.id)) }
  private var restoration: TaskWindowRestoration {
    .resolve(route: route, dataRoot: store.dataRoot, loaded: store.libraryLoaded,
      restoring: store.restoringLibrary || store.libraryLoading, readError: store.libraryReadError,
      taskExists: route.map { availableTasks.contains($0.taskID) } ?? false, hasPresentedTask: hasPresentedTask)
  }

  var body: some View {
    Group {
      if case .ready(let taskID) = restoration, let browser = browsers.tasks[taskID] {
        TaskWindowView(store: store, taskID: taskID, browser: browser, browsers: browsers, renameHistory: renameHistory,
          onNavigate: visit,
          canGoBack: navigation.destination(backwards: true, current: taskID, available: availableTasks) != nil,
          canGoForward: navigation.destination(backwards: false, current: taskID, available: availableTasks) != nil,
          onMove: move)
          .id(taskID)
      } else {
        restorationContent
          .frame(minWidth: 620, minHeight: 520)
          .focusedSceneValue(\.taskWindowCommands,
            TaskWindowCommandContext(enabled: ["tab-close"], perform: { _ in dismiss() }))
      }
    }
    .onDisappear { browsers.shutdown() }
    .task(id: restoration) {
      Self.logger.notice("Restoration: route=\(route != nil) loaded=\(store.libraryLoaded) restoring=\(store.restoringLibrary) taskExists=\(route.map { availableTasks.contains($0.taskID) } ?? false) closing=\(restoration == .close)")
      switch restoration {
      case .ready(let taskID):
        _ = browsers.browser(for: taskID, store: store)
        if store.library.recordTaskVisit(taskID) { store.saveLibrary() }
        hasPresentedTask = true
        if route?.dataRoot == nil { route = TaskWindowRoute(taskID: taskID, dataRoot: store.dataRoot) }
      case .close: dismiss()
      case .loading, .failed: break
      }
    }
  }

  @ViewBuilder private var restorationContent: some View {
    switch restoration {
    case .failed(let message):
      ContentUnavailableView {
        Label("无法恢复任务窗口", systemImage: "exclamationmark.triangle")
      } description: {
        Text(message)
      } actions: {
        Button("重试") { Task { await store.restore() } }
        Button("关闭窗口") { dismiss() }
      }
    case .loading: ProgressView("正在恢复任务…")
    case .close, .ready: Color.clear
    }
  }

  private func visit(_ taskID: String) {
    guard let route, navigation.visit(taskID, from: route.taskID, available: availableTasks) else { return }
    self.route = TaskWindowRoute(taskID: taskID, dataRoot: store.dataRoot)
  }

  private func move(_ backwards: Bool) {
    guard let route,
      let next = navigation.move(backwards: backwards, current: route.taskID, available: availableTasks) else { return }
    self.route = TaskWindowRoute(taskID: next, dataRoot: store.dataRoot)
  }
}
