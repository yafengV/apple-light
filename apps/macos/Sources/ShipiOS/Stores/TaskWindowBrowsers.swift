import AppKit
import Observation

/// Owned by the scene so navigating between tasks does not destroy their pages.
@MainActor @Observable final class TaskWindowBrowsers {
  private(set) var tasks: [String: TaskWindowBrowser] = [:]

  func browser(for taskID: String, store: WorkspaceStore) -> TaskWindowBrowser {
    if let existing = tasks[taskID] { return existing }
    let browser = TaskWindowBrowser()
    store.registerBrowserSession(browser.session)
    tasks[taskID] = browser
    return browser
  }

  func results(library: WorkspaceLibrary) -> [CommandBrowserResult] {
    library.tasks.flatMap { task in
      (tasks[task.id]?.session.tabs ?? []).filter { !$0.closed }.map { tab in
        CommandBrowserResult(id: tab.id.uuidString, owner: task.id, title: tab.title,
          pageTitle: tab.view.title ?? "", url: tab.committedURL?.absoluteString ?? "",
          ownerTitle: task.title)
      }
    }
  }

  func select(_ result: CommandBrowserResult, library: WorkspaceLibrary) -> Bool {
    guard library.tasks.contains(where: { $0.id == result.owner }),
      let browser = tasks[result.owner], let id = UUID(uuidString: result.id),
      browser.session.tabs.contains(where: { $0.id == id && !$0.closed }) else { return false }
    browser.visible = true
    browser.session.select(id)
    return true
  }

  func shutdown() { tasks.values.forEach { $0.session.shutdown() }; tasks = [:] }
}

@MainActor @Observable final class TaskWindowBrowser {
  let session = BrowserSession()
  var visible = false
  var fullWidth = false

  init() {
    session.onEmpty = { [weak self] in self?.visible = false }
  }

  func newTab() { visible = true; session.newTab() }
  func reopen() { if session.reopenClosedTab() != nil { visible = true } }
  func toggle() {
    visible.toggle()
    if visible { session.ensureTab(); if let id = session.selection { session.select(id) } }
  }
  func open(_ url: URL, presentation: MessageWebLinkPresentation) {
    guard BrowserAddress.permits(url) else { return }
    func document(_ url: URL) -> String {
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
      components?.fragment = nil
      return components?.string ?? url.absoluteString
    }
    let reusable = presentation.createsNewTab ? nil : session.tabs.last {
      !$0.closed && (($0.committedURL.map(document) == document(url) && !$0.loading)
        || ($0.committedURL == nil && $0.address == url.absoluteString))
    }
    let tab = reusable ?? session.newTab(activate: false)
    if tab.committedURL != url && (reusable == nil || tab.address != url.absoluteString || !tab.loading) {
      tab.address = url.absoluteString; tab.navigate()
    }
    visible = true
    if presentation != .backgroundTab { session.focusContent(tab.id) }
    else if session.selection == nil { session.select(tab.id, focus: false) }
    if presentation == .fullWidth { fullWidth = true }
    else if presentation == .split { fullWidth = false }
  }

  func commandEnabled(_ id: String) -> Bool {
    switch id {
    case "browser", "browser-new": return true
    case "browser-reopen": return session.canReopenClosedTab
    case "browser-address", "browser-close": return visible && session.selected != nil
    case "browser-back": return visible && session.selected?.canGoBack == true
    case "browser-forward": return visible && session.selected?.canGoForward == true
    case "browser-copy": return visible && session.selected?.committedURL != nil
    case "browser-reload", "browser-reload-origin": return visible && session.selected != nil
    case "workspace-view": return visible
    case "tab-close-others": return visible && session.tabs.count > 1
    case "next-task", "previous-task": return visible && session.tabs.count > 1
    default: return false
    }
  }

  func perform(_ id: String) {
    guard commandEnabled(id) else { return }
    switch id {
    case "browser": toggle()
    case "browser-new": newTab()
    case "browser-reopen": reopen()
    case "browser-address": session.focusAddress()
    case "browser-back": session.selected?.back()
    case "browser-forward": session.selected?.forward()
    case "browser-reload": session.selected?.reload()
    case "browser-reload-origin": session.selected?.reload(bypassCache: true)
    case "browser-copy": session.copyURL()
    case "browser-close": if let id = session.selection { session.close(id) }
    case "workspace-view": fullWidth.toggle()
    case "tab-close-others": if let id = session.selection { session.closeOtherTabs(keeping: id) }
    case "next-task": session.move(1)
    case "previous-task": session.move(-1)
    default: break
    }
  }
}
