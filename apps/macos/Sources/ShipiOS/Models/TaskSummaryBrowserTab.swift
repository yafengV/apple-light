import Foundation

struct TaskSummaryBrowserTab: Identifiable, Equatable {
  let id: UUID
  let title: String
  let url: URL

  var subtitle: String { url.host ?? url.absoluteString }
}

enum TaskSummaryBrowserTabs {
  @MainActor static func collect(owner: String, contentTabs: [WorkspaceContentTab],
    browserTabs: [BrowserTab]) -> [TaskSummaryBrowserTab] {
    let byID = Dictionary(browserTabs.filter { !$0.closed }.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first })
    var seen = Set<UUID>()
    return contentTabs.compactMap { contentTab in
      guard contentTab.owner == owner, let id = contentTab.browserID,
        seen.insert(id).inserted,
        let browser = byID[id],
        let url = browser.committedURL ?? (try? BrowserAddress.url(browser.address)),
        BrowserAddress.permits(url), url.absoluteString != "about:blank" else { return nil }
      let title = browser.title == "新标签页" || browser.title.isEmpty
        ? (url.host ?? url.absoluteString) : browser.title
      return TaskSummaryBrowserTab(id: id, title: title, url: url)
    }
  }
}
