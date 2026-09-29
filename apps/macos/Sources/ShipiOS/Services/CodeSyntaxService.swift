import CryptoKit
import AppKit
import Foundation
import WebKit

@MainActor protocol CodeSyntaxHighlighting {
  func highlight(_ input: CodeSyntaxInput) async throws -> CodeSyntaxResult
}

/// App-owned compute engine. It never attaches to a window, opens a website or
/// shares a browser profile; code crosses the boundary only as typed arguments.
@MainActor final class CodeSyntaxService: NSObject, CodeSyntaxHighlighting, WKNavigationDelegate {
  static let shared = CodeSyntaxService()
  private let resources: URL
  private(set) var view: WKWebView?
  private var loaded = false
  private var generation = UUID()
  private var waiting: [UUID: CheckedContinuation<Void, Error>] = [:]
  private var timeout: Task<Void, Never>?
  private var cache: [CodeSyntaxIdentity: CodeSyntaxResult] = [:]
  private var recency: [CodeSyntaxIdentity] = []
  private var costs: [CodeSyntaxIdentity: Int] = [:]
  private var cacheBytes = 0
  var usesIsolatedDocument: Bool {
    view != nil && view?.window == nil && view?.url?.absoluteString == "about:blank"
      && view?.configuration.websiteDataStore.isPersistent == false
  }
  init(resources: URL? = nil) {
    if let resources { self.resources = resources }
    else if Bundle.main.bundleURL.pathExtension == "app" {
      self.resources = Bundle.main.resourceURL!.appendingPathComponent("ShipiOS_ShipiOS.bundle/SyntaxHighlighting")
    } else { self.resources = Bundle.module.bundleURL.appendingPathComponent("SyntaxHighlighting") }
    super.init()
  }
  func highlight(_ input: CodeSyntaxInput) async throws -> CodeSyntaxResult {
    try Task.checkCancellation()
    if let value = cache[input.identity] { touch(input.identity); return value }
    try await ready(); try Task.checkCancellation()
    guard let view else { throw AgentFailure(message: "代码高亮引擎未连接。") }
    let arguments = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input))
    let result = try await view.callAsyncJavaScript("return await globalThis.shipiosSyntax.highlight(input)",
      arguments: ["input": arguments], in: nil, contentWorld: .defaultClient)
    try Task.checkCancellation()
    guard let object = result as? [String: Any] else { throw AgentFailure(message: "代码高亮引擎未返回有效结果。") }
    let value = try JSONDecoder().decode(CodeSyntaxResult.self, from: JSONSerialization.data(withJSONObject: object))
    try value.validate(input)
    cache[input.identity] = value; touch(input.identity)
    cacheBytes -= costs[input.identity] ?? 0
    let cost = input.lines.reduce(0) { $0 + $1.text.utf8.count * 4 }
      + (value.left + value.right).reduce(0) { $0 + $1.tokens.count * 128 }
    costs[input.identity] = cost; cacheBytes += cost
    while recency.count > 100 || cacheBytes > 16 * 1024 * 1024 {
      let removed = recency.removeFirst(); cache[removed] = nil
      cacheBytes -= costs.removeValue(forKey: removed) ?? 0
    }
    return value
  }
  private func touch(_ identity: CodeSyntaxIdentity) {
    recency.removeAll { $0 == identity }; recency.append(identity)
  }
  private func ready() async throws {
    if loaded { return }
    let token = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        waiting[token] = continuation
        if view == nil {
          do { try start() } catch { fail(error) }
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.waiting.removeValue(forKey: token)?.resume(throwing: CancellationError()) }
    }
  }
  private func start() throws {
    struct Manifest: Decodable { let format: Int; let sha256: String; let bytes: Int }
    let data = try Data(contentsOf: resources.appendingPathComponent("engine.js"))
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: resources.appendingPathComponent("manifest.json")))
    guard manifest.format == 1, manifest.bytes == data.count,
      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == manifest.sha256,
      let script = String(data: data, encoding: .utf8) else { throw AgentFailure(message: "代码高亮资源损坏。") }
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.userContentController.addUserScript(.init(source: script, injectionTime: .atDocumentStart,
      forMainFrameOnly: true, in: .defaultClient))
    _ = NSApplication.shared
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = self; self.view = view
    generation = UUID(); let token = generation
    timeout = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(8)) } catch { return }
      guard let self, self.generation == token, !self.loaded else { return }
      self.fail(AgentFailure(message: "代码高亮引擎启动超时。"))
    }
    view.loadHTMLString("<meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; script-src 'unsafe-eval'; connect-src 'none'\"><title>Syntax</title>", baseURL: nil)
  }
  private func fail(_ error: Error) {
    generation = UUID(); timeout?.cancel(); timeout = nil
    view?.navigationDelegate = nil; view?.stopLoading(); view = nil; loaded = false
    let pending = waiting.values; waiting.removeAll()
    for continuation in pending { continuation.resume(throwing: error) }
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard webView === view else { return }
    loaded = true; timeout?.cancel(); timeout = nil
    let pending = waiting.values; waiting.removeAll()
    for continuation in pending { continuation.resume() }
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { if webView === view { fail(error) } }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if webView === view { fail(error) } }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    if webView === view { fail(AgentFailure(message: "代码高亮进程已结束。")) }
  }
  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
  }
}
