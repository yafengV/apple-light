import WebKit

struct BrowserSiteTool: Identifiable, Equatable {
  let name: String
  let title: String
  let summary: String
  let readOnly: Bool
  let schemaJSON: String
  let registrationID: String
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
          context.registerTool = (tool, options = {}) => {
            if (options.signal?.aborted)
              return Promise.reject(new Error('Site tool registration cancelled'));
            if (!tool || typeof tool.name !== 'string' || typeof tool.execute !== 'function')
              return Promise.reject(new TypeError('Invalid site tool'));
            if (!/^[A-Za-z0-9_.-]{1,128}$/.test(tool.name))
              return Promise.reject(new TypeError('Invalid site tool name'));
            if (tools.has(tool.name))
              return Promise.reject(new Error('Site tool already registered'));
            const descriptor = {
              name: tool.name, title: tool.title, description: tool.description,
              inputSchema: tool.inputSchema, annotations: tool.annotations,
              window, origin: location.origin,
              registrationID: globalThis.crypto?.randomUUID?.() ?? Math.random().toString(36).slice(2)
            };
            tools.set(tool.name, { tool, descriptor });
            options.signal?.addEventListener('abort', () => {
              if (tools.get(tool.name)?.descriptor === descriptor) {
                tools.delete(tool.name);
                context.dispatchEvent(new Event('toolchange'));
              }
            }, { once: true });
            context.dispatchEvent(new Event('toolchange'));
            return Promise.resolve();
          };
          context.unregisterTool = name => {
            if (tools.delete(name)) context.dispatchEvent(new Event('toolchange'));
          };
          context.getTools = async () => Array.from(tools.values(), entry => entry.descriptor);
          context.executeTool = async (descriptor, args = {}, options = {}) => {
            const entry = tools.get(descriptor?.name);
            if (!entry || entry.descriptor !== descriptor)
              throw new Error('Site tool registration changed');
            const result = await entry.tool.execute(args, { signal: options.signal });
            return typeof result === 'string' ? result : JSON.stringify(result) ?? 'null';
          };
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
      tab.siteToolsRevision = UUID()
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
        return Array.from(catalog).filter(tool => !tool.window || tool.window === window)
          .slice(0, 64).map(tool => {
          let schemaJSON = '{}';
          try { schemaJSON = JSON.stringify(tool.inputSchema ?? {type:'object',properties:{}}) ?? '{}'; }
          catch (_) {}
          return {
            name: String(tool.name ?? '').slice(0, 128),
            title: String(tool.title ?? tool.name ?? '').slice(0, 160),
            summary: String(tool.description ?? '').slice(0, 500),
            readOnly: tool.annotations?.readOnlyHint === true,
            schemaJSON: schemaJSON.length <= 8192 ? schemaJSON : '{}',
            registrationID: String(tool.registrationID ?? '').slice(0, 80)
          };
        });
        """, arguments: [:], in: nil, contentWorld: .page)
      guard !closed, !loading, siteToolsRevision == revision else { return }
      let rows = value as? [[String: Any]] ?? []
      siteTools = rows.compactMap { row in
        guard let name = row["name"] as? String,
          name.range(of: "^[A-Za-z0-9_.-]{1,128}$", options: .regularExpression) != nil else { return nil }
        return BrowserSiteTool(name: name, title: row["title"] as? String ?? name,
          summary: row["summary"] as? String ?? "", readOnly: row["readOnly"] as? Bool ?? false,
          schemaJSON: row["schemaJSON"] as? String ?? "{}",
          registrationID: row["registrationID"] as? String ?? "")
      }
    } catch {
      if !closed, siteToolsRevision == revision { siteTools = [] }
    }
  }

  func executeSiteTool(_ tool: BrowserSiteTool, arguments: JSONValue) async throws -> String {
    guard !closed, !loading, committedURL != nil else {
      throw AgentFailure(message: "网页已关闭或正在导航。")
    }
    let data = try JSONEncoder().encode(arguments)
    guard data.count <= 8_192, let argumentString = String(data: data, encoding: .utf8) else {
      throw AgentFailure(message: "站点工具参数超过 8 KiB。")
    }
    let value = try await view.callAsyncJavaScript("""
      const catalog = await document.modelContext.getTools();
      const tool = Array.from(catalog).find(item => item.name === toolName
        && (!item.window || item.window === window));
      if (!tool || (registrationID && tool.registrationID !== registrationID))
        throw new Error('Site tool registration changed');
      const input = JSON.parse(argumentString);
      const controller = new AbortController();
      let timeout;
      const result = await Promise.race([
        document.modelContext.executeTool(tool, input, { signal: controller.signal }),
        new Promise((_, reject) => {
          timeout = setTimeout(() => {
            controller.abort();
            reject(new Error('Site tool timed out'));
          }, 30000);
        })
      ]).finally(() => clearTimeout(timeout));
      const output = typeof result === 'string' ? result : JSON.stringify(result) ?? 'null';
      return output.slice(0, 16001);
      """, arguments: ["toolName": tool.name, "registrationID": tool.registrationID,
        "argumentString": argumentString], in: nil, contentWorld: .page)
    return value as? String ?? "null"
  }
}
