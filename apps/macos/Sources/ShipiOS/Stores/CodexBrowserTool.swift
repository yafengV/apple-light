import AppKit
import WebKit

extension WorkspaceStore {
  func handleCodexBrowserRequest(taskID: String, token: UUID, request: JSONValue) async {
    guard codexBrowserRequestCurrent(taskID: taskID, token: token) else { return }
    guard let requestID = request["requestId"].text else { return }
    let result = await codexBrowserResult(
      taskID: taskID, action: request["action"].text ?? "", tabID: request["tabId"].text,
      requestedURL: request["url"].text, handle: request["handle"].text,
      text: request["text"].text, token: token)
    guard codexBrowserRequestCurrent(taskID: taskID, token: token) else { return }
    codexTransport.publishBrowserResult(taskID: taskID, requestID: requestID, result: result)
    try? await codexTransport.resolveBrowserRequest(taskID: taskID, requestID: requestID, result: result)
  }

  func codexBrowserResult(taskID: String, action: String, tabID: String?,
    requestedURL: String? = nil, handle: String? = nil, text: String? = nil,
    token: UUID? = nil) async -> JSONValue {
    guard codexBrowserRequestCurrent(taskID: taskID, token: token) else {
      return .object(["status": .string("cancelled")])
    }
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
      guard await allowCodexBrowserAccess(url: url, taskID: taskID, token: token) else {
        return .object(["status": .string("denied"), "url": .string(url.absoluteString)])
      }
      guard codexBrowserRequestCurrent(taskID: taskID, token: token) else {
        return .object(["status": .string("cancelled")])
      }
      guard let tab = openCodexBrowserTab(url: url, taskID: taskID) else {
        return .object(["status": .string("unavailable"), "message": .string("无法打开任务浏览器标签。")])
      }
      for _ in 0..<200 where tab.loading {
        if !codexBrowserRequestCurrent(taskID: taskID, token: token) {
          tab.stop(); tab.agentNavigationHost = nil
          return .object(["status": .string("cancelled")])
        }
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
    guard ["read", "inspect", "click", "fill"].contains(action),
      let tabID, let id = UUID(uuidString: tabID),
      let tab = tabs.first(where: { $0.id == id }),
      !tab.closed, !tab.loading, let url = tab.committedURL,
      BrowserAddress.permits(url), url.scheme?.lowercased() != "about" else {
      return .object(["status": .string("unavailable"),
        "message": .string("网页标签不存在、尚未加载完成或不可读取。")])
    }
    guard await allowCodexBrowserAccess(url: url, taskID: taskID, token: token) else {
      return .object(["status": .string("denied"), "host": .string(url.host ?? "")])
    }
    guard codexBrowserRequestCurrent(taskID: taskID, token: token) else {
      return .object(["status": .string("cancelled")])
    }
    guard !tab.closed, !tab.loading, tab.committedURL == url,
      codexBrowserTabs(taskID: taskID).contains(where: { $0 === tab }) else {
      return .object(["status": .string("unavailable"),
        "message": .string("授权期间网页已变化，请重新列出标签。")])
    }
    if action != "read" {
      return await interactWithCodexBrowser(tab: tab, taskID: taskID, action: action,
        url: url, handle: handle, text: text, token: token)
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

  private func interactWithCodexBrowser(tab: BrowserTab, taskID: String,
    action: String, url: URL, handle: String?, text: String?, token: UUID?) async -> JSONValue {
    do {
      if action == "inspect" {
        let inspected = try await BrowserAgentDOM.inspect(tab)
        guard codexBrowserTabs(taskID: taskID).contains(where: { $0 === tab }),
          !tab.closed, !tab.loading, tab.committedURL == url else {
          return .object(["status": .string("unavailable"),
            "message": .string("检查期间网页已变化，请重新列出标签。")])
        }
        return .object(["status": .string("ok"), "tab_id": .string(tab.id.uuidString),
          "url": .string(url.absoluteString), "title": .string(tab.title),
          "elements": inspected["elements"], "truncated": inspected["truncated"]])
      }
      guard let handle, handle.utf8.count <= 100, handle.utf8.allSatisfy({ $0 < 128 }),
        handle.contains(":"), action != "fill" || text.map({ $0.unicodeScalars.count <= 4_000 }) == true else {
        return .object(["status": .string("error"), "message": .string("请使用页面检查返回的元素句柄；填写文字最多 4000 字。")])
      }
      let target = try await BrowserAgentDOM.target(tab, handle: handle)
      guard codexBrowserTabs(taskID: taskID).contains(where: { $0 === tab }),
        !tab.closed, !tab.loading, tab.committedURL == url else {
        return .object(["status": .string("unavailable"),
          "message": .string("操作前网页已变化，请重新检查网页。")])
      }
      if target["disabled"].boolean == true {
        return .object(["status": .string("error"), "message": .string("元素已禁用。")])
      }
      if action == "click" {
        if let href = target["href"].text, !href.isEmpty {
          guard let link = try? BrowserAddress.url(href) else {
            return .object(["status": .string("error"),
              "message": .string("链接地址不安全或不受支持。")])
          }
          if link.host?.lowercased() != url.host?.lowercased() {
            return .object(["status": .string("denied"), "host": .string(link.host ?? ""),
              "message": .string("目标链接属于其他网站，请使用 open 单独打开并授权。")])
          }
        }
        if let destination = target["target"].text, !destination.isEmpty,
          destination != "_self" {
          return .object(["status": .string("error"),
            "message": .string("新窗口链接请使用 open 单独打开。")])
        }
        let tag = target["tag"].text ?? ""
        let inputAction = tag == "input" && ["submit", "button", "reset", "image", "checkbox", "radio"]
          .contains(target["type"].text?.lowercased() ?? "")
        if tag == "button" || inputAction || target["role"].text == "button" {
          guard await confirmCodexBrowserControl(target, url: url, taskID: taskID,
            token: token) else {
            return .object(["status": .string("denied"), "host": .string(url.host ?? "")])
          }
        }
      }
      guard codexBrowserRequestCurrent(taskID: taskID, token: token),
        codexBrowserTabs(taskID: taskID).contains(where: { $0 === tab }),
        !tab.closed, !tab.loading, tab.committedURL == url else {
        return .object(["status": .string("unavailable"),
          "message": .string("确认期间网页或任务归属已变化。")])
      }
      if browserPermissionPreferences.decision(for: url) == .block {
        return .object(["status": .string("denied"), "host": .string(url.host ?? "")])
      }
      tab.agentNavigationHost = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
      defer { tab.agentNavigationHost = nil }
      try await BrowserAgentDOM.perform(tab, action: action, handle: handle, text: text)
      try? await Task.sleep(for: .milliseconds(200))
      for _ in 0..<200 where tab.loading {
        if !codexBrowserRequestCurrent(taskID: taskID, token: token) {
          tab.stop()
          return .object(["status": .string("cancelled")])
        }
        try? await Task.sleep(for: .milliseconds(100))
      }
      if tab.loading {
        tab.stop()
        return .object(["status": .string("error"), "message": .string("网页操作后加载超时。")])
      }
      if let error = tab.error {
        return .object(["status": .string("error"), "message": .string(error)])
      }
      guard codexBrowserTabs(taskID: taskID).contains(where: { $0 === tab }),
        !tab.closed, let currentURL = tab.committedURL else {
        return .object(["status": .string("unavailable"), "message": .string("网页标签已关闭。")])
      }
      if action == "fill" && currentURL != url {
        return .object(["status": .string("unavailable"), "message": .string("填写期间网页已变化。")])
      }
      return .object(["status": .string("ok"), "tab_id": .string(tab.id.uuidString),
        "url": .string(currentURL.absoluteString), "title": .string(tab.title),
        "action": .string(action), "label": .string(target["label"].text ?? "")])
    } catch {
      return .object(["status": .string("error"), "message": .string(error.localizedDescription)])
    }
  }

  private func confirmCodexBrowserControl(_ target: JSONValue, url: URL,
    taskID: String, token: UUID?) async -> Bool {
    let taskWindow = taskWindowResources.allObjects.first {
      $0.tasks[taskID] != nil && $0.window?.isVisible == true
    }?.window
    let mainWindow = selectedTask?.id == taskID
      ? NSApp.windows.first { $0.identifier?.rawValue == "main" && $0.isVisible } : nil
    guard let window = taskWindow ?? mainWindow, window.attachedSheet == nil else { return false }
    let rawLabel = target["label"].text ?? ""
    let label = rawLabel.isEmpty ? "页面按钮" : rawLabel
    let allowed = await withCheckedContinuation { continuation in
      let alert = NSAlert()
      alert.messageText = "允许 Agent 点击“\(label)”吗？"
      alert.informativeText = "网站：\(url.host ?? "未知网站")。请确认此操作符合你的任务。"
      alert.addButton(withTitle: "取消")
      alert.addButton(withTitle: "允许点击")
      alert.beginSheetModal(for: window) { response in
        continuation.resume(returning: response == .alertSecondButtonReturn)
      }
      expireCodexBrowserAlert(alert, in: window, taskID: taskID, token: token)
    }
    return allowed && codexBrowserRequestCurrent(taskID: taskID, token: token)
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

  private func allowCodexBrowserAccess(url: URL, taskID: String,
    token: UUID?) async -> Bool {
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
      expireCodexBrowserAlert(alert, in: window, taskID: taskID, token: token)
    }
    guard codexBrowserRequestCurrent(taskID: taskID, token: token) else { return false }
    switch decision {
    case .alertSecondButtonReturn: return true
    case .alertThirdButtonReturn:
      return url.host.map { setBrowserSiteAccess($0, decision: .allow) } ?? false
    default: return false
    }
  }

  private func codexBrowserRequestCurrent(taskID: String, token: UUID?) -> Bool {
    token.map { codexTransport.browserRequestIsCurrent(taskID: taskID, token: $0) } ?? true
  }

  private func expireCodexBrowserAlert(_ alert: NSAlert, in window: NSWindow,
    taskID: String, token: UUID?) {
    Task { @MainActor [weak self, weak window] in
      for _ in 0..<300 {
        try? await Task.sleep(for: .milliseconds(200))
        guard let self, let window,
          window.attachedSheet === alert.window else { return }
        if !self.codexBrowserRequestCurrent(taskID: taskID, token: token) {
          window.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
          return
        }
      }
      if let window, window.attachedSheet === alert.window {
        window.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
      }
    }
  }
}
