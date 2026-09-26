import WebKit

/// The native first responder is WebKit's content view for both page text and
/// ordinary page content. Report DOM editing focus before routing arrow keys.
final class BrowserEditableFocusHandler: NSObject, WKScriptMessageHandler {
  private final class WeakController {
    weak var value: WKUserContentController?
    init(_ value: WKUserContentController) { self.value = value }
  }
  private static let shared = BrowserEditableFocusHandler()
  @MainActor private static var controllers: [WeakController] = []
  private static let name = "shipiosEditableFocus"

  @MainActor static func install(on configuration: WKWebViewConfiguration) {
    let controller = configuration.userContentController
    controllers.removeAll { $0.value == nil }
    guard !controllers.contains(where: { $0.value === controller }) else { return }
    controllers.append(WeakController(controller))
    controller.add(shared, contentWorld: .defaultClient, name: name)
    controller.addUserScript(script)
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    MainActor.assumeIsolated {
      guard let tab = (message.webView as? BrowserWebView)?.browserTab, !tab.closed,
        let body = message.body as? [String: Any],
        let frame = body["frame"] as? String, let editable = body["editable"] as? Bool else { return }
      tab.setPageEditableFocus(frame: frame, editable: editable)
    }
  }

  private static var script: WKUserScript {
    let source = """
    (() => {
      const frame = Math.random().toString(36).slice(2) + String(Date.now());
      const excluded = new Set(['button', 'checkbox', 'color', 'file', 'hidden', 'image',
        'radio', 'range', 'reset', 'submit']);
      const editable = () => {
        const element = document.activeElement;
        if (!element || element.disabled || element.readOnly) return false;
        if (element.isContentEditable || element instanceof HTMLTextAreaElement) return true;
        return element instanceof HTMLInputElement && !excluded.has(element.type);
      };
      const post = (value) => {
        try { window.webkit.messageHandlers.shipiosEditableFocus?.postMessage({ frame, editable: value }); }
        catch (_) {}
      };
      const update = () => post(editable());
      document.addEventListener('focusin', update, true);
      document.addEventListener('focusout', () => queueMicrotask(update), true);
      window.addEventListener('blur', () => post(false), true);
      window.addEventListener('pagehide', () => post(false), true);
    })();
    """
    return WKUserScript(source: source, injectionTime: .atDocumentStart,
      forMainFrameOnly: false, in: .defaultClient)
  }
}
