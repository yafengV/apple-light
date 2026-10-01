import WebKit

struct BrowserSiteTool: Identifiable, Equatable {
  let name: String
  let title: String
  let summary: String
  let readOnly: Bool
  var id: String { name }
}

/// WebMCP is exposed in the page world because the website itself registers its tools.
/// Only the main frame is considered; iframe registrations never enter the catalog.
final class BrowserSiteToolHandler: NSObject, WKScriptMessageHandler {
  private final class WeakController {
    weak var value: WKUserContentController?
    init(_ value: WKUserContentController) { self.value = value }
  }
  private static let shared = BrowserSiteToolHandler()
  @MainActor private static var controllers: [WeakController] = []

  @MainActor static func install(on configuration: WKWebViewConfiguration) {
    let controller = configuration.userContentController
    controllers.removeAll { $0.value == nil }
    guard !controllers.contains(where: { $0.value === controller }) else { return }
    controllers.append(WeakController(controller))
    controller.add(shared, contentWorld: .page, name: "shipiosSiteTools")
    controller.addUserScript(WKUserScript(source: """
      (() => {
        if (!window.isSecureContext) return;
        const notify = () => {
          try { window.webkit.messageHandlers.shipiosSiteTools.postMessage('changed'); }
          catch (_) {}
        };
        if (!document.modelContext) {
          const tools = new Map();
          const context = new EventTarget();
          context.registerTool = tool => {
            if (!tool || typeof tool.name !== 'string' || typeof tool.execute !== 'function')
              throw new TypeError('Invalid site tool');
            if (!/^[A-Za-z0-9_.-]{1,128}$/.test(tool.name))
              throw new TypeError('Invalid site tool name');
            tools.set(tool.name, tool);
            context.dispatchEvent(new Event('toolchange'));
          };
          context.unregisterTool = name => {
            if (tools.delete(name)) context.dispatchEvent(new Event('toolchange'));
          };
          context.getTools = () => Array.from(tools.values());
          Object.defineProperty(document, 'modelContext', { value: context, configurable: false });
        }
        document.modelContext.addEventListener?.('toolchange', notify);
      })();
      """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
  }

  func userContentController(_ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage) {
    MainActor.assumeIsolated {
      guard message.frameInfo.isMainFrame, message.body as? String == "changed",
        let tab = (message.webView as? BrowserWebView)?.browserTab, !tab.closed else { return }
      Task { await tab.refreshSiteTools() }
    }
  }
}

extension BrowserTab {
  func refreshSiteTools() async {
    let revision = siteToolsRevision
    guard !closed, !loading, committedURL != nil else { return }
    do {
      let value = try await view.callAsyncJavaScript("""
        const catalog = await Promise.resolve(document.modelContext?.getTools?.() ?? []);
        return Array.from(catalog).slice(0, 64).map(tool => ({
          name: String(tool.name ?? '').slice(0, 128),
          title: String(tool.title ?? tool.name ?? '').slice(0, 160),
          summary: String(tool.description ?? '').slice(0, 500),
          readOnly: tool.annotations?.readOnlyHint === true
        }));
        """, arguments: [:], in: nil, contentWorld: .page)
      guard !closed, !loading, siteToolsRevision == revision else { return }
      let rows = value as? [[String: Any]] ?? []
      siteTools = rows.compactMap { row in
        guard let name = row["name"] as? String,
          name.range(of: "^[A-Za-z0-9_.-]{1,128}$", options: .regularExpression) != nil else { return nil }
        return BrowserSiteTool(name: name, title: row["title"] as? String ?? name,
          summary: row["summary"] as? String ?? "", readOnly: row["readOnly"] as? Bool ?? false)
      }
    } catch {
      if !closed, siteToolsRevision == revision { siteTools = [] }
    }
  }
}
