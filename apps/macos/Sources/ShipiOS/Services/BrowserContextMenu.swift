import AppKit
import WebKit

struct BrowserContextTarget: Equatable {
  let pageURL: URL
  let linkURL: URL?
  let reference: BrowserElementReference

  var openURL: URL { linkURL ?? pageURL }
}

@MainActor
final class BrowserWebView: WKWebView {
  weak var browserTab: BrowserTab?

  override func rightMouseDown(with event: NSEvent) {
    guard let browserTab else {
      super.rightMouseDown(with: event)
      return
    }
    let nativeMenu = super.menu(for: event)
    browserTab.presentContextMenu(for: event, nativeMenu: nativeMenu)
  }
}

extension BrowserTab {
  func contextTarget(at viewPoint: NSPoint) async -> BrowserContextTarget? {
    guard !closed, let pageURL = committedURL else { return nil }
    let cssY = max(0, view.isFlipped ? viewPoint.y : view.bounds.height - viewPoint.y)
    do {
      let result = try await view.callAsyncJavaScript(
        Self.contextTargetScript,
        arguments: ["x": max(0, viewPoint.x), "y": cssY],
        in: nil,
        contentWorld: .page)
      guard !closed, committedURL == pageURL,
        let value = result as? [String: Any],
        let selector = value["selector"] as? String,
        let tag = value["tag"] as? String
      else { return nil }
      let linkURL = (value["link"] as? String).flatMap(URL.init(string:))
      let reference = BrowserElementReference(
        url: pageURL.absoluteString,
        pageTitle: title,
        selector: String(selector.prefix(1_024)),
        tag: String(tag.prefix(80)),
        text: String((value["text"] as? String ?? "").prefix(500)),
        accessibilityLabel: String((value["label"] as? String ?? "").prefix(300)),
        role: String((value["role"] as? String ?? "").prefix(80)),
        rect: Self.selectionRect(value["rect"]))
      return BrowserContextTarget(pageURL: pageURL, linkURL: linkURL, reference: reference)
    } catch {
      return nil
    }
  }

  func presentContextMenu(for event: NSEvent, nativeMenu: NSMenu?) {
    let point = view.convert(event.locationInWindow, from: nil)
    let window = view.window
    Task { @MainActor [weak self] in
      guard let self, let target = await contextTarget(at: point), !closed,
        view.window === window else { return }
      let menu = makeContextMenu(for: target, nativeMenu: nativeMenu)
      NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
  }

  func makeContextMenu(for target: BrowserContextTarget, nativeMenu: NSMenu? = nil) -> NSMenu {
    contextTarget = target
    nativeInspectTarget = nil
    nativeInspectAction = nil
    let menu = NSMenu()
    if target.linkURL != nil {
      menu.addItem(item("复制链接地址", #selector(copyContextLink)))
      menu.addItem(.separator())
    }
    let back = item("后退", #selector(contextBack)); back.isEnabled = canGoBack
    let forward = item("前进", #selector(contextForward)); forward.isEnabled = canGoForward
    menu.addItem(back)
    menu.addItem(forward)
    menu.addItem(item("重新加载", #selector(contextReload)))
    menu.addItem(.separator())
    menu.addItem(item("在外部浏览器中打开", #selector(openContextExternally)))
    if target.linkURL != nil {
      menu.addItem(item("在新标签页中打开链接", #selector(openContextInNewTab)))
    }
    if let inspect = nativeMenu?.items.first(where: {
      $0.title.localizedCaseInsensitiveContains("inspect") || $0.title.contains("检查")
    }), let action = inspect.action {
      nativeInspectTarget = inspect.target as AnyObject?
      nativeInspectAction = action
    }
    menu.addItem(item("检查", #selector(inspectContextElement)))
    menu.addItem(.separator())
    menu.addItem(item("使用 Codex 评论", #selector(commentOnContextElement)))
    return menu
  }

  func copyContextLink(to pasteboard: NSPasteboard = .general) {
    guard let url = contextTarget?.linkURL else { return }
    pasteboard.clearContents()
    pasteboard.setString(url.absoluteString, forType: .string)
  }

  func useContextTargetForComment(_ target: BrowserContextTarget) {
    selectedElement = target.reference
    elementSelectionError = nil
  }

  private func item(_ title: String, _ action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  @objc private func copyContextLink() { copyContextLink(to: .general) }
  @objc private func contextBack() { back() }
  @objc private func contextForward() { forward() }
  @objc private func contextReload() { reload() }
  @objc private func openContextExternally() {
    guard let url = contextTarget?.openURL else { return }
    NSWorkspace.shared.open(url)
  }
  @objc private func openContextInNewTab() {
    guard let url = contextTarget?.linkURL else { return }
    openURLInNewTab?(url)
  }
  @objc private func inspectContextElement() {
    if let action = nativeInspectAction,
      NSApp.sendAction(action, to: nativeInspectTarget, from: view) { return }
    guard let inspector = view.perform(NSSelectorFromString("_inspector"))?.takeUnretainedValue()
      as? NSObject else { return }
    let show = NSSelectorFromString("show")
    if inspector.responds(to: show) { inspector.perform(show) }
  }
  @objc private func commentOnContextElement() {
    guard let target = contextTarget else { return }
    useContextTargetForComment(target)
  }

  static let contextTargetScript = #"""
    const pointX = Number(x);
    const pointY = Number(y);
    const element = document.elementFromPoint(pointX, pointY) || document.body || document.documentElement;
    if (!element) return null;
    const selectorFor = (target) => {
      if (target.id) return "#" + CSS.escape(target.id);
      const parts = [];
      let node = target;
      while (node && node.nodeType === Node.ELEMENT_NODE && parts.length < 7) {
        let part = node.tagName.toLowerCase();
        const classes = Array.from(node.classList || []).filter(Boolean).slice(0, 2);
        if (classes.length) part += "." + classes.map((value) => CSS.escape(value)).join(".");
        const parent = node.parentElement;
        if (parent) {
          const siblings = Array.from(parent.children).filter((item) => item.tagName === node.tagName);
          if (siblings.length > 1) part += `:nth-of-type(${siblings.indexOf(node) + 1})`;
        }
        parts.unshift(part);
        node = parent;
        if (node === document.body) { parts.unshift("body"); break; }
      }
      return parts.join(" > ");
    };
    const anchor = element.closest?.("a[href]");
    const rect = element.getBoundingClientRect();
    return {
      selector: selectorFor(element).slice(0, 1024),
      tag: element.tagName.toLowerCase().slice(0, 80),
      text: (element.innerText || element.textContent || "").trim().replace(/\s+/g, " ").slice(0, 500),
      label: (element.getAttribute("aria-label") || element.getAttribute("alt") || element.getAttribute("title") || "").trim().slice(0, 300),
      role: (element.getAttribute("role") || "").trim().slice(0, 80),
      link: anchor ? anchor.href : "",
      rect: {
        x: rect.left + window.scrollX, y: rect.top + window.scrollY,
        width: rect.width, height: rect.height,
      },
    };
  """#
}
