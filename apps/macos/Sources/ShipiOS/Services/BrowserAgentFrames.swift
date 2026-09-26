import WebKit

/// Keeps WebKit frame handles in the same isolated world used by Agent DOM tools.
/// A frame token is regenerated on navigation; stale WKFrameInfo values are checked
/// against that token before any page content is inspected.
final class BrowserAgentFrameHandler: NSObject, WKScriptMessageHandler {
  private final class WeakController {
    weak var value: WKUserContentController?
    init(_ value: WKUserContentController) { self.value = value }
  }
  private static let shared = BrowserAgentFrameHandler()
  @MainActor private static var controllers: [WeakController] = []
  private static let name = "shipiosAgentFrame"

  @MainActor static func install(on configuration: WKWebViewConfiguration) {
    let controller = configuration.userContentController
    controllers.removeAll { $0.value == nil }
    guard !controllers.contains(where: { $0.value === controller }) else { return }
    controllers.append(WeakController(controller))
    controller.add(shared, contentWorld: BrowserAgentDOM.world, name: name)
    controller.addUserScript(WKUserScript(source: """
      (() => {
        const id = (typeof crypto !== 'undefined' && crypto.randomUUID)
          ? crypto.randomUUID() : Math.random().toString(36).slice(2) + Date.now();
        globalThis.__shipiosAgentFrameID = id;
        const post = event => {
          try { window.webkit.messageHandlers.shipiosAgentFrame.postMessage({ event, id }); }
          catch (_) {}
        };
        post('ready');
        window.addEventListener('pagehide', () => post('gone'), { once: true });
      })();
      """, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: BrowserAgentDOM.world))
  }

  func userContentController(_ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage) {
    MainActor.assumeIsolated {
      guard let tab = (message.webView as? BrowserWebView)?.browserTab, !tab.closed,
        let body = message.body as? [String: Any],
        let id = body["id"] as? String, id.count <= 80,
        let event = body["event"] as? String else { return }
      if event == "ready" { tab.agentFrames[id] = message.frameInfo }
      else if event == "gone" { tab.agentFrames[id] = nil }
    }
  }
}
