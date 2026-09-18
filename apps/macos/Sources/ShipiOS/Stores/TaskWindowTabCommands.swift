import Foundation

extension TaskWindowTabs {
  func commandEnabled(_ id: String) -> Bool {
    let page = focused?.browserID.flatMap { id in browser.session.tabs.first { $0.id == id } }
    switch id {
    case "browser", "browser-new", "workspace-tabs": return true
    case "browser-reopen": return canReopen
    case "browser-address", "browser-close", "browser-reload", "browser-reload-origin": return page != nil
    case "browser-back": return page?.canGoBack == true
    case "browser-forward": return page?.canGoForward == true
    case "browser-copy": return page?.committedURL != nil
    case "workspace-view": return focused != nil || tabs.contains(where: { $0.id == lastContentForCommand })
    case "workspace-swap-panes": return showingRight || panels.showingFiles
    case "tab-close-others":
      let place = focusedID.map(placement) ?? .left
      return visibleTabs(place).count > (focused == nil ? 0 : 1)
    case "next-task", "previous-task": return !tabs.isEmpty
    default: return false
    }
  }

  @discardableResult func perform(_ id: String) -> Bool {
    guard commandEnabled(id) else { return false }
    let page = focused?.browserID.flatMap { id in browser.session.tabs.first { $0.id == id } }
    switch id {
    case "browser":
      if let tab = focused, tab.browserID != nil {
        if placement(tab.id) == .left { activate(nil) } else { hide(placement(tab.id)) }
      } else if let tab = tabs.first(where: { $0.browserID != nil }) { activate(tab.id) }
      else { newBrowser() }
    case "browser-new": newBrowser()
    case "browser-reopen": reopen()
    case "browser-address": browser.session.focusAddress()
    case "browser-back": page?.back()
    case "browser-forward": page?.forward()
    case "browser-reload": page?.reload()
    case "browser-reload-origin": page?.reload(bypassCache: true)
    case "browser-copy": browser.session.copyURL()
    case "browser-close": if let id = focusedID { close(id) }
    case "workspace-view": toggleFullWidth()
    case "workspace-tabs": showingTabs.toggle()
    case "workspace-swap-panes": primarySide.swap()
    case "tab-close-others": closeOthers(keeping: focusedID, in: focusedID.map(placement) ?? .left)
    case "next-task": cycle(1)
    case "previous-task": cycle(-1)
    default: return false
    }
    return true
  }
}
