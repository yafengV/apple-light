import Foundation

extension WorkspaceStore {
  var browserPermissionPreferences: BrowserPermissionPreferences {
    library.browserPermissions
  }

  func setBrowserDefaultAccess(_ decision: BrowserAccessDecision) {
    do {
      var candidate = library
      candidate.browserPermissions.defaultDecision = decision
      try commitLibrary(candidate)
      browserSettingsError = nil
    } catch { browserSettingsError = error.localizedDescription }
  }

  func setBrowserSiteAccess(_ input: String, decision: BrowserAccessDecision) -> Bool {
    do {
      let host = try BrowserPermissionPreferences.normalizedHost(input)
      var candidate = library
      if decision == .ask {
        candidate.browserPermissions.sites[host] = nil
      } else {
        candidate.browserPermissions.sites[host] = decision
      }
      try commitLibrary(candidate)
      browserSettingsError = nil
      return true
    } catch {
      browserSettingsError = error.localizedDescription
      return false
    }
  }

  func removeBrowserSiteAccess(_ host: String) {
    do {
      var candidate = library
      candidate.browserPermissions.sites[host] = nil
      try commitLibrary(candidate)
      browserSettingsError = nil
    } catch { browserSettingsError = error.localizedDescription }
  }

  func recordBrowserVisit(_ url: URL, title: String) {
    guard BrowserAddress.permits(url) else { return }
    do {
      var candidate = library
      let existingID = candidate.browserHistory.first { $0.url == url.absoluteString }?.id
      candidate.browserHistory.removeAll { $0.url == url.absoluteString }
      candidate.browserHistory.insert(
        BrowserHistoryEntry(
          id: existingID ?? UUID(), url: url.absoluteString, title: title, visitedAt: Date()),
        at: 0)
      if candidate.browserHistory.count > 500 {
        candidate.browserHistory.removeLast(candidate.browserHistory.count - 500)
      }
      try commitLibrary(candidate)
      browserSettingsError = nil
    } catch { browserSettingsError = error.localizedDescription }
  }

  func openBrowserHistory(_ entry: BrowserHistoryEntry) {
    guard let url = URL(string: entry.url), BrowserAddress.permits(url) else {
      browserSettingsError = "历史记录中的网址无效。"
      return
    }
    destination = .workspace
    pane = "browser"
    let tab = workspace.browser.newTab()
    tab.address = url.absoluteString
    tab.navigate()
  }

  func removeBrowserHistory(_ id: UUID) {
    do {
      var candidate = library
      candidate.browserHistory.removeAll { $0.id == id }
      try commitLibrary(candidate)
      browserSettingsError = nil
    } catch { browserSettingsError = error.localizedDescription }
  }

  func clearBrowserHistory() {
    do {
      var candidate = library
      candidate.browserHistory = []
      try commitLibrary(candidate)
      browserSettingsError = nil
    } catch { browserSettingsError = error.localizedDescription }
  }

  func clearBrowserData(includeHistory: Bool) async {
    await workspace.browser.clearWebsiteData()
    for session in additionalBrowserSessions.allObjects
      where session.dataStore !== workspace.browser.dataStore {
      await session.clearWebsiteData()
    }
    if includeHistory { clearBrowserHistory() }
  }
}
