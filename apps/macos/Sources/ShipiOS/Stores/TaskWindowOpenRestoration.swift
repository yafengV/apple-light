import Foundation

extension WorkspaceStore {
  var taskWindowRestorationReady: Bool {
    libraryLoaded && scopeLoaded && !restoringLibrary && !libraryLoading
      && !modelConfigurationLoading && restorationReadError == nil && !shuttingDown
  }

  /// Record only attached task scenes, never background layout caches.
  func rememberTaskWindow(_ resources: TaskWindowResources) {
    guard libraryLoaded, !shuttingDown, !resources.isClosed, resources.window != nil,
      let taskID = resources.displayedTaskID, library.tasks.contains(where: { $0.id == taskID }) else { return }
    let route = TaskWindowRoute(taskID: taskID, dataRoot: dataRoot, windowID: resources.id)
    taskWindowRouteOwners[route.id] = ObjectIdentifier(resources)
    guard library.openTaskWindowRoutes.first(where: { $0.id == route.id }) != route else { return }
    library.openTaskWindowRoutes.removeAll { $0.id == route.id }
    library.openTaskWindowRoutes.append(route)
    saveLibrary()
  }

  func forgetTaskWindow(_ resources: TaskWindowResources) {
    guard taskWindowRouteOwners[resources.id] == ObjectIdentifier(resources) else { return }
    taskWindowRouteOwners[resources.id] = nil
    // App termination tears down resources too; those scenes must reopen next launch.
    guard !shuttingDown else { return }
    library.openTaskWindowRoutes.removeAll { $0.id == resources.id }
  }

  /// The main scene consumes this once. SwiftUI reuses an already restored value;
  /// attached scenes are omitted so OS restoration and application recovery cannot duplicate them.
  func takePendingTaskWindowRoutes() -> [TaskWindowRoute] {
    guard taskWindowRestorationReady, !taskWindowRestorationClaimed else { return [] }
    taskWindowRestorationClaimed = true
    let root = TaskWindowRoute.workspacePath(dataRoot)
    let available = Set(library.tasks.map(\.id))
    var seen = Set<String>()
    let routes = library.openTaskWindowRoutes.filter {
      ($0.dataRoot == nil || $0.dataRoot == root) && available.contains($0.taskID)
        && !$0.id.isEmpty && seen.insert($0.id).inserted
    }.map { TaskWindowRoute(taskID: $0.taskID, dataRoot: dataRoot, windowID: $0.id) }
    if library.openTaskWindowRoutes != routes {
      library.openTaskWindowRoutes = routes
      saveLibrary()
    }
    let attached = Set(taskWindowResources.allObjects.filter {
      !$0.isClosed && $0.window != nil
    }.map(\.id))
    return routes.filter { !attached.contains($0.id) }
  }
}
