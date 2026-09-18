import Foundation

enum TaskWindowRestoration: Equatable {
  case loading
  case failed(String)
  case ready(String)
  case close

  static func resolve(route: TaskWindowRoute?, dataRoot: URL, loaded: Bool, restoring: Bool,
    readError: String?, taskExists: Bool, hasPresentedTask: Bool) -> Self {
    if let savedRoot = route?.dataRoot, savedRoot != TaskWindowRoute.workspacePath(dataRoot) { return .close }
    if restoring { return .loading }
    if !loaded {
      if let readError { return .failed(readError) }
      return .loading
    }
    // SwiftUI can attach the restored value after the scene first appears.
    guard let route else { return .loading }
    // A restored stale route should not leave an unusable window at launch.
    // A task deleted while this window is open keeps its navigation/close UI.
    guard taskExists || hasPresentedTask else { return .close }
    return .ready(route.taskID)
  }
}
