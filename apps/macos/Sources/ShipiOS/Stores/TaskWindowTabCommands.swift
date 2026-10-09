import Foundation

extension TaskWindowTabs {
  func commandEnabled(_ id: String) -> Bool {
    let page = commandContentTab?.browserID.flatMap { id in browser.session.tabs.first { $0.id == id } }
    switch id {
    case "browser", "browser-new", "workspace-tabs": return true
    case "browser-reopen": return canReopen
    case "browser-address", "browser-close", "browser-reload", "browser-reload-origin": return page != nil
    case "browser-back": return page?.canGoBack == true
    case "browser-forward": return page?.canGoForward == true
    case "browser-copy": return page?.committedURL != nil
    case "browser-comment-mode": return page?.canToggleCommentMode == true
    case "workspace-view": return true
    case "workspace-swap-panes": return showsContentSidePanel || panels.showingFiles
    case "tab-close-others":
      let place = commandContentTab.map { stripPlacement($0.id) } ?? .left
      return presentedTabs(place).count > (commandContentTab == nil ? 0 : 1)
    case "next-tab", "previous-tab": return !tabs.isEmpty
    case let value where value.hasPrefix("focus-tab-"):
      guard let slot = DesktopCommand.numberSlot(value) else { return false }
      return numberedTabIDs.indices.contains(slot.index - 1)
    default: return false
    }
  }

  @discardableResult func perform(_ id: String) -> Bool {
    guard commandEnabled(id) else { return false }
    let page = commandContentTab?.browserID.flatMap { id in browser.session.tabs.first { $0.id == id } }
    switch id {
    case "browser": toggleContentVisibility()
    case "browser-new": newBrowser()
    case "browser-reopen": reopen()
    case "browser-address": if let page { browser.session.focusAddress(tabID: page.id) }
    case "browser-back": page?.back()
    case "browser-forward": page?.forward()
    case "browser-reload": page?.reload()
    case "browser-reload-origin": page?.reload(bypassCache: true)
    case "browser-copy": if let page { browser.session.copyURL(tabID: page.id) }
    case "browser-comment-mode": page?.toggleCommentMode()
    case "browser-close": if let id = commandContentTab?.id { close(id) }
    case "workspace-view": toggleFullWidth()
    case "workspace-tabs": showingTabs.toggle()
    case "workspace-swap-panes": primarySide.swap()
    case "tab-close-others":
      closeOthers(keeping: commandContentTab?.id, in: commandContentTab.map { stripPlacement($0.id) } ?? .left)
    case "next-tab": return navigateAdjacentContentTab(1)
    case "previous-tab": return navigateAdjacentContentTab(-1)
    case let value where value.hasPrefix("focus-tab-"):
      guard let slot = DesktopCommand.numberSlot(value) else { return false }
      return focusSlot(slot.index)
    default: return false
    }
    return true
  }
  @discardableResult func navigateAdjacentContentTab(_ direction: Int) -> Bool {
    let place = focused.map { stripPlacement($0.id) } ?? .left
    let full = effectiveContentLayoutMode == .full
    guard full || focused != nil else { return false }
    let content = place == .bottom ? visibleTabs(.bottom) : primaryContentTabs
    let ids: [String?] = (full && place != .bottom ? [nil] : []) + content.map { Optional($0.id) }
    guard ids.count > 1 else { return false }
    let current = focused?.id ?? selected(place)?.id
    let index = ids.firstIndex { $0 == current } ?? 0
    activate(ids[(index + direction + ids.count) % ids.count]); return true
  }

}
