import SwiftUI
import OSLog

/// History and task resources survive navigation within this window.
struct TaskWindowSceneView: View {
  private static let logger = Logger(subsystem: "dev.shipios.desktop", category: "WindowRestoration")
  @Bindable var store: WorkspaceStore
  @Binding var route: TaskWindowRoute?
  @State private var renameHistory = TaskRenameHistory()
  @State private var resources = TaskWindowResources()
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
      if case .ready(let taskID) = restoration, let tabs = resources.tasks[taskID] {
        TaskWindowView(store: store, taskID: taskID, tabs: tabs, resources: resources, renameHistory: renameHistory,
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
    .background(TaskWindowResourceAttachment(resources: resources).frame(width: 0, height: 0))
    .onAppear { resources.navigate = visit }
    .onChange(of: route) { _, _ in resources.navigate = visit }
    .onDisappear { resources.shutdown() }
    .onChange(of: availableTasks) { _, available in
      resources.retainTasks(available, displaying: route?.taskID)
    }
    .task(id: restoration) {
      Self.logger.notice("Restoration: route=\(route != nil) loaded=\(store.libraryLoaded) restoring=\(store.restoringLibrary) taskExists=\(route.map { availableTasks.contains($0.taskID) } ?? false) closing=\(restoration == .close)")
      switch restoration {
      case .ready(let taskID):
        resources.retainTasks(availableTasks, displaying: taskID)
        resources.prepare(taskID, store: store)
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

private struct TaskWindowResourceAttachment: NSViewRepresentable {
  let resources: TaskWindowResources
  func makeNSView(context: Context) -> Attachment { Attachment(resources: resources) }
  func updateNSView(_ view: Attachment, context: Context) {}
  final class Attachment: NSView {
    weak var resources: TaskWindowResources?
    init(resources: TaskWindowResources) { self.resources = resources; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow(); resources?.attach(window: window, from: self)
    }
  }
}
