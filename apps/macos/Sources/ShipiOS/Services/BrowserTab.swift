import AppKit
import Observation
import WebKit

struct BrowserElementReference: Codable, Equatable, Sendable {
  let url: String
  let pageTitle: String
  let selector: String
  let tag: String
  let text: String
  let accessibilityLabel: String
  let role: String
  var selectionKind = "element"
  var rect: BrowserSelectionRect?

  var title: String {
    if !accessibilityLabel.isEmpty { return accessibilityLabel }
    if !text.isEmpty { return text }
    return selector
  }

  var promptContext: String {
    var lines = [
      "网页元素：\(title)",
      "页面：\(pageTitle.isEmpty ? url : pageTitle)",
      "网址：\(url)",
      "选择器：\(selector)",
      "标签：\(tag)",
    ]
    if !role.isEmpty { lines.append("角色：\(role)") }
    if !text.isEmpty { lines.append("文本：\(text)") }
    return lines.joined(separator: "\n")
  }
}

@MainActor @Observable
final class BrowserTab: NSObject, Identifiable, WKNavigationDelegate, WKUIDelegate,
  WKDownloadDelegate
{
  let id: UUID
  var address = ""
  var editingAddress = false
  private(set) var title = "新标签页"
  private(set) var loading = false
  private(set) var canGoBack = false
  private(set) var canGoForward = false
  private(set) var committedURL: URL?
  private(set) var error: String?
  private(set) var closed = false
  private(set) var selectingElement = false
  var selectedElement: BrowserElementReference?
  var elementSelectionError: String?
  private(set) var capturingSnapshot = false
  private(set) var snapshotError: String?
  @ObservationIgnored let view: BrowserWebView
  @ObservationIgnored var openWindow: ((WKWebViewConfiguration) -> BrowserTab?)?
  @ObservationIgnored var openURLInNewTab: ((URL) -> Void)?
  @ObservationIgnored var closeWindow: (() -> Void)?
  @ObservationIgnored var didVisit: ((URL, String) -> Void)?
  @ObservationIgnored var chooseDownloadDestination:
    ((URL, String, @escaping (BrowserDownloadDestination) -> Void) -> Void)?
  @ObservationIgnored var didUpdateDownload: ((BrowserDownloadEvent) -> Void)?
  @ObservationIgnored private var observations: [NSKeyValueObservation] = []
  @ObservationIgnored private var activeNavigation: WKNavigation?
  @ObservationIgnored private var downloads: [UUID: WKDownload] = [:]
  @ObservationIgnored private var pendingDownloads = Set<UUID>()
  @ObservationIgnored private var downloadDestinationOverrides: [UUID: BrowserDownloadDestinationChooser] = [:]
  @ObservationIgnored private var downloadIDs: [ObjectIdentifier: UUID] = [:]
  @ObservationIgnored private var downloadSources: [ObjectIdentifier: URL] = [:]
  @ObservationIgnored private var downloadProgress: [ObjectIdentifier: NSKeyValueObservation] = [:]
  @ObservationIgnored var contextTarget: BrowserContextTarget?
  @ObservationIgnored var nativeInspectTarget: AnyObject?
  @ObservationIgnored var nativeInspectAction: Selector?

  init(configuration: WKWebViewConfiguration, id: UUID = UUID()) {
    self.id = id
    configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
    view = BrowserWebView(frame: .zero, configuration: configuration)
    super.init()
    view.browserTab = self
    if #available(macOS 13.3, *) { view.isInspectable = true }
    view.navigationDelegate = self
    view.uiDelegate = self
    view.allowsBackForwardNavigationGestures = true
    observations = [
      view.observe(\.title) { [weak self] _, _ in
        Task { @MainActor in self?.sync(); self?.recordVisit() }
      },
      view.observe(\.url) { [weak self] _, _ in
        Task { @MainActor in self?.sync(); self?.recordVisit() }
      },
      view.observe(\.isLoading) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
      view.observe(\.canGoBack) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
      view.observe(\.canGoForward) { [weak self] _, _ in Task { @MainActor in self?.sync() } },
    ]
  }
  func navigate() {
    guard !closed else { return }
    do {
      let url = try BrowserAddress.url(address)
      address = url.absoluteString
      editingAddress = false
      error = nil
      loading = true
      activeNavigation = view.load(URLRequest(url: url))
    } catch { self.error = error.localizedDescription }
  }
  func back() { guard canGoBack, !closed else { return }; error = nil; activeNavigation = view.goBack() }
  func forward() { guard canGoForward, !closed else { return }; error = nil; activeNavigation = view.goForward() }
  func reload(bypassCache: Bool = false) {
    guard !closed else { return }
    error = nil
    if view.url == nil { navigate() }
    else { activeNavigation = bypassCache ? view.reloadFromOrigin() : view.reload() }
  }
  func stop() { view.stopLoading(); loading = false }
  func restoreAddress() { editingAddress = false; address = committedURL?.absoluteString ?? "" }
  func close() {
    guard !closed else { return }
    cancelElementSelection()
    closed = true
    view.stopLoading()
    for id in Array(downloads.keys) + Array(pendingDownloads) { _ = cancelDownload(id) }
    view.navigationDelegate = nil; view.uiDelegate = nil
    contextTarget = nil; nativeInspectTarget = nil; nativeInspectAction = nil
    observations = []; openWindow = nil; openURLInNewTab = nil; closeWindow = nil; didVisit = nil
    chooseDownloadDestination = nil; didUpdateDownload = nil
  }
  @discardableResult func cancelDownload(_ id: UUID) -> Bool {
    if pendingDownloads.remove(id) != nil {
      downloadDestinationOverrides[id] = nil
      didUpdateDownload?(.cancelled(id: id))
      return true
    }
    guard let download = downloads[id] else { return false }
    didUpdateDownload?(.cancelled(id: id))
    cleanup(download)
    download.cancel { _ in }
    return true
  }
  @discardableResult func downloadURL(_ url: URL,
    chooseDestination: BrowserDownloadDestinationChooser? = nil) -> UUID? {
    guard !closed, BrowserAddress.permits(url) else { return nil }
    let id = UUID()
    pendingDownloads.insert(id)
    downloadDestinationOverrides[id] = chooseDestination
    didUpdateDownload?(.started(id: id, sourceURL: url.absoluteString,
      filename: url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent))
    view.startDownload(using: URLRequest(url: url)) { [weak self] download in
      guard let self, !self.closed, self.pendingDownloads.remove(id) != nil else {
        download.cancel { _ in }
        return
      }
      self.beginDownload(download, sourceURL: url, id: id)
    }
    return id
  }
  @discardableResult func selectElement() async -> BrowserElementReference? {
    guard !closed, committedURL != nil, !loading, !selectingElement else { return nil }
    selectingElement = true
    selectedElement = nil
    elementSelectionError = nil
    defer { selectingElement = false }
    do {
      let result = try await view.callAsyncJavaScript(
        Self.elementPickerScript, arguments: [:], in: nil, contentWorld: .page)
      guard !closed, let value = result as? [String: Any],
        let selector = value["selector"] as? String,
        let tag = value["tag"] as? String
      else { return nil }
      let reference = BrowserElementReference(
        url: committedURL?.absoluteString ?? "",
        pageTitle: title,
        selector: String(selector.prefix(1_024)),
        tag: String(tag.prefix(80)),
        text: String((value["text"] as? String ?? "").prefix(500)),
        accessibilityLabel: String((value["label"] as? String ?? "").prefix(300)),
        role: String((value["role"] as? String ?? "").prefix(80)),
        selectionKind: value["kind"] as? String == "region" ? "region" : "element",
        rect: Self.selectionRect(value["rect"]))
      selectedElement = reference
      return reference
    } catch {
      guard !closed else { return nil }
      elementSelectionError = "无法选择网页元素：\(error.localizedDescription)"
      return nil
    }
  }
  func cancelElementSelection() {
    guard selectingElement else { return }
    view.evaluateJavaScript("window.__shipiosElementPicker?.cancel?.(); undefined")
  }
  func clearSelectedElement() {
    selectedElement = nil
    elementSelectionError = nil
  }
  @discardableResult func snapshotPNG() async -> Data? {
    guard !closed, let expectedURL = committedURL, !loading, !selectingElement,
      !capturingSnapshot else { return nil }
    let bounds = view.bounds
    guard bounds.width > 0, bounds.height > 0 else {
      snapshotError = "网页区域尚未准备好，请稍后重试。"
      return nil
    }
    capturingSnapshot = true
    snapshotError = nil
    defer { capturingSnapshot = false }
    do {
      let configuration = WKSnapshotConfiguration()
      configuration.rect = bounds
      configuration.afterScreenUpdates = true
      let image = try await view.takeSnapshot(configuration: configuration)
      guard !closed, committedURL == expectedURL, !loading else {
        throw AgentFailure(message: "网页已发生变化，请重新截图。")
      }
      guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
        let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
      else { throw AgentFailure(message: "无法生成网页截图。") }
      return data
    } catch {
      guard !closed else { return nil }
      snapshotError = error.localizedDescription
      return nil
    }
  }
  func clearSnapshotError() { snapshotError = nil }
  func renderCommentMarkers(_ comments: [BrowserComment]) async {
    guard !closed, let url = committedURL?.absoluteString else { return }
    let items: [[String: Any]] = comments.enumerated().compactMap { index, comment in
      guard comment.reference.url == url else { return nil }
      var value: [String: Any] = [
        "number": index + 1,
        "selector": comment.reference.selector,
        "kind": comment.reference.selectionKind,
      ]
      if let rect = comment.reference.rect {
        value["rect"] = [
          "x": rect.x, "y": rect.y, "width": rect.width, "height": rect.height,
        ]
      }
      return value
    }
    _ = try? await view.callAsyncJavaScript(
      Self.commentMarkerScript, arguments: ["items": items], in: nil, contentWorld: .page)
  }
  static func selectionRect(_ value: Any?) -> BrowserSelectionRect? {
    guard let value = value as? [String: Any],
      let x = (value["x"] as? NSNumber)?.doubleValue,
      let y = (value["y"] as? NSNumber)?.doubleValue,
      let width = (value["width"] as? NSNumber)?.doubleValue,
      let height = (value["height"] as? NSNumber)?.doubleValue
    else { return nil }
    return BrowserSelectionRect(x: x, y: y, width: width, height: height)
  }
  private func sync() {
    guard !closed else { return }
    loading = view.isLoading
    canGoBack = view.canGoBack; canGoForward = view.canGoForward
    if committedURL != view.url {
      committedURL = view.url
      if !editingAddress, let url = view.url { address = url.absoluteString }
    }
    title = view.title.flatMap { $0.isEmpty ? nil : $0 } ?? view.url?.host ?? "新标签页"
  }
  private func recordVisit() {
    guard !loading, let url = committedURL else { return }
    didVisit?(url, title)
  }
  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    guard !closed else { return }
    cancelElementSelection()
    selectedElement = nil
    elementSelectionError = nil
    snapshotError = nil
    activeNavigation = navigation; error = nil; sync()
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard navigation === activeNavigation else { return }
    sync()
    recordVisit()
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(navigation, error) }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(navigation, error) }
  private func failed(_ navigation: WKNavigation?, _ error: Error) {
    guard !closed, navigation === activeNavigation else { return }
    loading = false
    let nsError = error as NSError
    // WebKit reports policy-converted downloads with WKErrorDomain code 102.
    let becameDownload = nsError.domain.lowercased().contains("webkit")
      && nsError.code == 102
    if nsError.code != NSURLErrorCancelled, !becameDownload {
      self.error = error.localizedDescription
    }
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    loading = false; error = "网页进程已结束，请重新加载。"
  }
  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard !closed, let url = navigationAction.request.url, BrowserAddress.permits(url) else {
      error = "此浏览器面板只支持 http 和 https 网页。"
      decisionHandler(.cancel); return
    }
    decisionHandler(.allow)
  }
  func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
    decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    guard !closed else {
      decisionHandler(.cancel)
      return
    }
    let disposition = (navigationResponse.response as? HTTPURLResponse)?
      .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
    if disposition.contains("attachment") || !navigationResponse.canShowMIMEType {
      decisionHandler(.download)
    } else {
      decisionHandler(.allow)
    }
  }
  func webView(_ webView: WKWebView, navigationAction: WKNavigationAction,
    didBecome download: WKDownload) {
    beginDownload(download, sourceURL: navigationAction.request.url)
  }
  func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
    didBecome download: WKDownload) {
    beginDownload(download, sourceURL: navigationResponse.response.url)
  }
  func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
    suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
    let key = ObjectIdentifier(download)
    guard let id = downloadIDs[key], let source = downloadSources[key] ?? response.url else {
      completionHandler(nil)
      return
    }
    let filename = suggestedFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "download" : suggestedFilename
    didUpdateDownload?(.started(
      id: id, sourceURL: source.absoluteString, filename: filename))
    guard let chooseDownloadDestination = downloadDestinationOverrides[id] ?? chooseDownloadDestination else {
      didUpdateDownload?(.cancelled(id: id))
      cleanup(download)
      completionHandler(nil)
      return
    }
    chooseDownloadDestination(source, filename) { [weak self, weak download] destination in
      guard let self, let download, self.downloadIDs[ObjectIdentifier(download)] == id else {
        completionHandler(nil)
        return
      }
      switch destination {
      case .save(let destination):
        self.didUpdateDownload?(.destination(id: id, url: destination))
        completionHandler(destination)
      case .cancel:
        self.didUpdateDownload?(.cancelled(id: id))
        self.cleanup(download)
        completionHandler(nil)
      case .failure(let message):
        self.didUpdateDownload?(.failed(id: id, message: message))
        self.cleanup(download)
        completionHandler(nil)
      }
    }
  }
  func downloadDidFinish(_ download: WKDownload) {
    guard let id = downloadIDs[ObjectIdentifier(download)] else { return }
    didUpdateDownload?(.finished(id: id))
    cleanup(download)
  }
  func download(_ download: WKDownload, didFailWithError error: Error,
    resumeData: Data?) {
    guard let id = downloadIDs[ObjectIdentifier(download)] else { return }
    let nsError = error as NSError
    if nsError.code == NSURLErrorCancelled {
      didUpdateDownload?(.cancelled(id: id))
    } else {
      didUpdateDownload?(.failed(id: id, message: error.localizedDescription))
    }
    cleanup(download)
  }
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    guard !closed, let url = navigationAction.request.url, BrowserAddress.permits(url),
      let create = openWindow, let tab = create(configuration) else { return nil }
    tab.address = url.absoluteString
    return tab.view
  }
  func webViewDidClose(_ webView: WKWebView) { closeWindow?() }

  private func beginDownload(_ download: WKDownload, sourceURL: URL?, id: UUID = UUID()) {
    guard let sourceURL, BrowserAddress.permits(sourceURL) else {
      download.cancel { _ in }
      return
    }
    let key = ObjectIdentifier(download)
    downloads[id] = download
    downloadIDs[key] = id
    downloadSources[key] = sourceURL
    download.delegate = self
    downloadProgress[key] = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
      Task { @MainActor in
        guard let self, let id = self.downloadIDs[key] else { return }
        self.didUpdateDownload?(.progress(id: id, fraction: progress.fractionCompleted))
      }
    }
  }

  private func cleanup(_ download: WKDownload) {
    let key = ObjectIdentifier(download)
    if let id = downloadIDs.removeValue(forKey: key) {
      downloads[id] = nil
      downloadDestinationOverrides[id] = nil
    }
    downloadSources[key] = nil
    downloadProgress[key]?.invalidate()
    downloadProgress[key] = nil
    download.delegate = nil
  }

  private static let elementPickerScript = #"""
    return await new Promise((resolve) => {
      const key = "__shipiosElementPicker";
      if (window[key] && window[key].cancel) window[key].cancel();
      let current = null;
      let previous = null;
      let settled = false;
      const drag = { start: null, active: false, box: null };
      const restore = () => {
        if (!current || !previous) return;
        current.style.outline = previous.outline;
        current.style.outlineOffset = previous.outlineOffset;
        current.style.cursor = previous.cursor;
        current = null;
        previous = null;
      };
      const selectorFor = (element) => {
        if (element.id) return "#" + CSS.escape(element.id);
        const parts = [];
        let node = element;
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
      const dataFor = (element, kind, rect) => ({
        selector: selectorFor(element).slice(0, 1024),
        tag: element.tagName.toLowerCase().slice(0, 80),
        text: (element.innerText || element.textContent || "").trim().replace(/\s+/g, " ").slice(0, 500),
        label: (element.getAttribute("aria-label") || element.getAttribute("alt") || element.getAttribute("title") || "").trim().slice(0, 300),
        role: (element.getAttribute("role") || "").trim().slice(0, 80),
        kind,
        rect,
      });
      const pageRect = (rect) => ({
        x: rect.left + window.scrollX, y: rect.top + window.scrollY,
        width: rect.width, height: rect.height,
      });
      const cleanup = () => {
        restore();
        if (drag.box) drag.box.remove();
        document.removeEventListener("mouseover", hover, true);
        document.removeEventListener("mousedown", down, true);
        document.removeEventListener("mousemove", move, true);
        document.removeEventListener("mouseup", up, true);
        document.removeEventListener("click", choose, true);
        document.removeEventListener("keydown", keydown, true);
        delete window[key];
      };
      const finish = (value) => {
        if (settled) return;
        settled = true;
        cleanup();
        resolve(value);
      };
      const hover = (event) => {
        if (drag.start) return;
        const element = event.target;
        if (!(element instanceof Element) || element === current) return;
        restore();
        current = element;
        previous = {
          outline: element.style.outline,
          outlineOffset: element.style.outlineOffset,
          cursor: element.style.cursor,
        };
        element.style.outline = "2px solid #7c5cff";
        element.style.outlineOffset = "2px";
        element.style.cursor = "crosshair";
      };
      const down = (event) => {
        if (event.button !== 0 || !(event.target instanceof Element)) return;
        drag.start = { x: event.clientX, y: event.clientY, target: event.target };
        drag.active = false;
      };
      const move = (event) => {
        if (!drag.start) return;
        const left = Math.min(drag.start.x, event.clientX);
        const top = Math.min(drag.start.y, event.clientY);
        const width = Math.abs(event.clientX - drag.start.x);
        const height = Math.abs(event.clientY - drag.start.y);
        if (!drag.active && Math.hypot(width, height) < 8) return;
        drag.active = true;
        restore();
        if (!drag.box) {
          drag.box = document.createElement("div");
          Object.assign(drag.box.style, {
            position: "fixed", pointerEvents: "none", zIndex: "2147483647",
            border: "2px solid #7c5cff", background: "rgba(124, 92, 255, .10)",
          });
          document.documentElement.appendChild(drag.box);
        }
        Object.assign(drag.box.style, {
          left: `${left}px`, top: `${top}px`, width: `${width}px`, height: `${height}px`,
        });
        event.preventDefault();
        event.stopImmediatePropagation();
      };
      const up = (event) => {
        if (!drag.start) return;
        const start = drag.start;
        drag.start = null;
        if (!drag.active) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        const left = Math.min(start.x, event.clientX);
        const top = Math.min(start.y, event.clientY);
        const rect = {
          x: left + window.scrollX, y: top + window.scrollY,
          width: Math.abs(event.clientX - start.x),
          height: Math.abs(event.clientY - start.y),
        };
        const swallow = (click) => {
          click.preventDefault(); click.stopImmediatePropagation();
          document.removeEventListener("click", swallow, true);
        };
        document.addEventListener("click", swallow, true);
        setTimeout(() => document.removeEventListener("click", swallow, true), 500);
        finish(dataFor(start.target, "region", rect));
      };
      const choose = (event) => {
        const element = event.target;
        if (!(element instanceof Element)) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        finish(dataFor(element, "element", pageRect(element.getBoundingClientRect())));
      };
      const keydown = (event) => {
        if (event.key !== "Escape") return;
        event.preventDefault();
        event.stopImmediatePropagation();
        finish(null);
      };
      window[key] = { cancel: () => finish(null) };
      document.addEventListener("mouseover", hover, true);
      document.addEventListener("mousedown", down, true);
      document.addEventListener("mousemove", move, true);
      document.addEventListener("mouseup", up, true);
      document.addEventListener("click", choose, true);
      document.addEventListener("keydown", keydown, true);
    });
    """#

  private static let commentMarkerScript = #"""
    const key = "__shipiosCommentMarkers";
    if (window[key] && window[key].cleanup) window[key].cleanup();
    const values = Array.isArray(items) ? items : [];
    const container = document.createElement("div");
    container.setAttribute("data-shipios-comments", "");
    Object.assign(container.style, {
      position: "absolute", inset: "0", pointerEvents: "none", zIndex: "2147483646",
    });
    document.documentElement.appendChild(container);
    const draw = () => {
      container.replaceChildren();
      for (const item of values) {
        let rect = item.rect || null;
        if (item.kind !== "region" && item.selector) {
          try {
            const element = document.querySelector(item.selector);
            if (element) {
              const bounds = element.getBoundingClientRect();
              rect = {
                x: bounds.left + scrollX, y: bounds.top + scrollY,
                width: bounds.width, height: bounds.height,
              };
            }
          } catch (_) {}
        }
        if (!rect || rect.width <= 0 || rect.height <= 0) continue;
        const outline = document.createElement("div");
        Object.assign(outline.style, {
          position: "absolute", left: `${rect.x}px`, top: `${rect.y}px`,
          width: `${rect.width}px`, height: `${rect.height}px`,
          border: "2px solid #1677ff", boxSizing: "border-box", borderRadius: "3px",
        });
        const marker = document.createElement("span");
        marker.textContent = String(item.number);
        Object.assign(marker.style, {
          position: "absolute", left: "-11px", top: "-11px", width: "22px", height: "22px",
          borderRadius: "11px", background: "#1677ff", color: "white",
          font: "600 12px -apple-system", display: "grid", placeItems: "center",
          boxShadow: "0 1px 4px rgba(0,0,0,.3)",
        });
        outline.appendChild(marker);
        container.appendChild(outline);
      }
    };
    const refresh = () => requestAnimationFrame(draw);
    window.addEventListener("resize", refresh);
    window[key] = {
      cleanup: () => {
        window.removeEventListener("resize", refresh);
        container.remove();
        delete window[key];
      },
    };
    draw();
    return values.length;
    """#
}
