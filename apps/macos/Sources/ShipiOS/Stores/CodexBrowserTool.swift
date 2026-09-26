import AppKit
import WebKit

extension WorkspaceStore {
  func handleCodexBrowserRequest(taskID: String, request: JSONValue) async {
    guard let requestID = request["requestId"].text else { return }
    let result = await codexBrowserResult(
      taskID: taskID, action: request["action"].text ?? "", tabID: request["tabId"].text,
      requestedURL: request["url"].text)
    codexTransport.publishBrowserResult(taskID: taskID, requestID: requestID, result: result)
    try? await codexTransport.resolveBrowserRequest(taskID: taskID, requestID: requestID, result: result)
  }

  func codexBrowserResult(taskID: String, action: String, tabID: String?,
    requestedURL: String? = nil) async -> JSONValue {
    guard library.tasks.contains(where: { $0.id == taskID && !$0.archived }) else {
      return .object(["status": .string("unavailable"), "message": .string("任务已不可用。")])
    }
    let tabs = codexBrowserTabs(taskID: taskID)
    if action == "list" {
      return .object(["status": .string("ok"), "tabs": .array(tabs.map { tab in .object([
        "tab_id": .string(tab.id.uuidString),
        "host": .string(tab.committedURL?.host ?? ""),
      ]) })])
    }
    if action == "open" {
      guard let requestedURL, requestedURL.utf8.count <= 2_048,
        let url = try? BrowserAddress.url(requestedURL),
        url.absoluteString == requestedURL else {
        return .object(["status": .string("error"), "message": .string("请提供不含凭据的完整 http/https 网址。")])
      }
      guard await allowCodexBrowserAccess(url: url, taskID: taskID) else {
        return .object(["status": .string("denied"), "url": .string(url.absoluteString)])
      }
      guard let tab = openCodexBrowserTab(url: url, taskID: taskID) else {
        return .object(["status": .string("unavailable"), "message": .string("无法打开任务浏览器标签。")])
      }
      for _ in 0..<200 where tab.loading {
        try? await Task.sleep(for: .milliseconds(100))
      }
      let timedOut = tab.loading
      if timedOut { tab.stop() }
      tab.agentNavigationHost = nil
      if timedOut {
        return .object(["status": .string("error"), "message": .string("网页加载超时。")])
      }
      if let error = tab.error {
        return .object(["status": .string("error"), "message": .string(error)])
      }
      return .object(["status": .string("ok"),
        "tab_id": .string(tab.id.uuidString), "url": .string(tab.committedURL?.absoluteString ?? url.absoluteString),
        "title": .string(tab.title)])
    }
    guard action == "read", let tabID, let id = UUID(uuidString: tabID),
      let tab = tabs.first(where: { $0.id == id }),
      !tab.closed, !tab.loading, let url = tab.committedURL,
      BrowserAddress.permits(url), url.scheme?.lowercased() != "about" else {
      return .object(["status": .string("unavailable"),
        "message": .string("网页标签不存在、尚未加载完成或不可读取。")])
    }
    guard await allowCodexBrowserAccess(url: url, taskID: taskID) else {
      return .object(["status": .string("denied"), "host": .string(url.host ?? "")])
    }
    guard !tab.closed, !tab.loading, tab.committedURL == url,
      codexBrowserTabs(taskID: taskID).contains(where: { $0 === tab }) else {
      return .object(["status": .string("unavailable"),
        "message": .string("授权期间网页已变化，请重新列出标签。")])
    }
    do {
      let value = try await tab.view.evaluateJavaScript("document.body?.innerText || ''")
      guard !tab.closed, !tab.loading, tab.committedURL == url,
        codexBrowserTabs(taskID: taskID).contains(where: { $0 === tab }) else {
        return .object(["status": .string("unavailable"),
          "message": .string("读取期间网页已变化。")])
      }
      let body = String((value as? String ?? "").prefix(8_000))
      return .object(["status": .string("ok"), "tab_id": .string(tab.id.uuidString),
        "title": .string(tab.title), "url": .string(url.absoluteString), "text": .string(body),
        "truncated": .bool((value as? String ?? "").count > 8_000)])
    } catch {
      return .object(["status": .string("error"), "message": .string(error.localizedDescription)])
    }
  }

  private func codexBrowserTabs(taskID: String) -> [BrowserTab] {
    let mainIDs = Set(workspaceTabs.filter { $0.owner == taskID }.compactMap(\.browserID))
    var tabs = workspace.browser.tabs.filter { mainIDs.contains($0.id) && !$0.closed }
    for resources in taskWindowResources.allObjects {
      guard let taskTabs = resources.tasks[taskID] else { continue }
      let ids = Set(taskTabs.tabs.compactMap(\.browserID))
      tabs.append(contentsOf: taskTabs.browser.session.tabs.filter { ids.contains($0.id) && !$0.closed })
    }
    return tabs.sorted { $0.id.uuidString < $1.id.uuidString }
  }

  private func openCodexBrowserTab(url: URL, taskID: String) -> BrowserTab? {
    if let resources = taskWindowResources.allObjects.first(where: {
      $0.tasks[taskID] != nil && $0.window?.isVisible == true
    }), let tabs = resources.tasks[taskID] {
      tabs.newBrowser(in: .right)
      let tab = tabs.browser.session.selected
      tab?.agentNavigationHost = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
      tab?.address = url.absoluteString
      tab?.navigate()
      return tab
    }
    if selectedTask?.id == taskID {
      newBrowserTab(in: .right)
      let tab = workspace.browser.selected
      tab?.agentNavigationHost = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
      tab?.address = url.absoluteString
      tab?.navigate()
      return tab
    }
    // Background turns keep their own tab and layout without changing the visible task.
    reopeningWorkspaceTabOwner = taskID
    let tab = workspace.browser.newTab(activate: false)
    reopeningWorkspaceTabOwner = nil
    tab.agentNavigationHost = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    tab.address = url.absoluteString
    tab.navigate()
    let id = WorkspaceContentTab.browser(tab.id, owner: taskID).id
    workspaceTabPlacements[id] = .right
    var layout = library.workspaceTabLayouts[taskID] ?? WorkspaceTabLayout(tabs: [],
      showingInspector: false, showingTerminal: false, showingTabs: true, side: .left,
      reviewScope: library.gitPreferences.defaultReviewScope)
    if let saved = savedBrowserTab(id) { layout.tabs.append(saved) }
    layout.right = id
    layout.showingInspector = true
    library.workspaceTabLayouts[taskID] = layout
    saveLibrary()
    return tab
  }

  private func allowCodexBrowserAccess(url: URL, taskID: String) async -> Bool {
    switch browserPermissionPreferences.decision(for: url) {
    case .allow: return true
    case .block: return false
    case .ask: break
    }
    let taskWindow = taskWindowResources.allObjects.first {
      $0.tasks[taskID] != nil && $0.window?.isVisible == true
    }?.window
    let mainWindow = selectedTask?.id == taskID
      ? NSApp.windows.first { $0.identifier?.rawValue == "main" && $0.isVisible } : nil
    guard let window = taskWindow ?? mainWindow, window.attachedSheet == nil else { return false }
    let decision = await withCheckedContinuation { continuation in
      let alert = NSAlert()
      alert.messageText = "允许 Agent 访问 \(url.host ?? "此网站")？"
      alert.informativeText = "Agent 可打开并读取此网站。你可以只允许本次，或在浏览器设置中管理网站规则。"
      alert.addButton(withTitle: "拒绝")
      alert.addButton(withTitle: "本次允许")
      alert.addButton(withTitle: "始终允许")
      alert.beginSheetModal(for: window) { response in continuation.resume(returning: response) }
      DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
        if window.attachedSheet === alert.window {
          window.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
        }
      }
    }
    switch decision {
    case .alertSecondButtonReturn: return true
    case .alertThirdButtonReturn:
      return url.host.map { setBrowserSiteAccess($0, decision: .allow) } ?? false
    default: return false
    }
  }
}
