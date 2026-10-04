import AppKit
import ObjectiveC

@MainActor protocol WindowModalScope: AnyObject {
  var modalRoot: NSView { get }
  var modalScopeActive: Bool { get }
  var blocksWorkspaceCommands: Bool { get }
}

@MainActor extension WindowModalScope {
  var blocksWorkspaceCommands: Bool { false }
}

/// A window owns a short-lived weak scope. Blocking interaction must not change
/// the enabled appearance of its retained controls, or affect another window.
@MainActor enum WindowModalInteraction {
  private static var key: UInt8 = 0
  private final class Holder {
    weak var scope: (any WindowModalScope)?
    init(_ scope: any WindowModalScope) { self.scope = scope }
  }
  static func install(_ scope: any WindowModalScope, in window: NSWindow) {
    objc_setAssociatedObject(window, &key, Holder(scope), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
  }
  static func remove(_ scope: any WindowModalScope, from window: NSWindow) {
    guard (objc_getAssociatedObject(window, &key) as? Holder)?.scope === scope else { return }
    objc_setAssociatedObject(window, &key, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
  }
  static func blocksCommands(in window: NSWindow?) -> Bool {
    guard let window, let scope = (objc_getAssociatedObject(window, &key) as? Holder)?.scope,
      scope.modalScopeActive else { return false }
    return scope.blocksWorkspaceCommands
  }
  static func allows(_ view: NSView) -> Bool {
    guard let window = view.window, let scope = (objc_getAssociatedObject(window, &key) as? Holder)?.scope,
      scope.modalScopeActive else { return true }
    return view === scope.modalRoot || view.isDescendant(of: scope.modalRoot)
  }
}
