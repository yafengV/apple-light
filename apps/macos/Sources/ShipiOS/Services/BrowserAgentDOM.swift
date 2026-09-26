import Foundation
import WebKit

/// Browser elements are kept in an isolated JavaScript world, scoped to one document scan.
@MainActor
enum BrowserAgentDOM {
  static let world = WKContentWorld.world(name: "ShipiOS.Agent")

  struct Frame {
    let id: String
    let info: WKFrameInfo
    let url: URL
  }

  static func availableFrames(_ tab: BrowserTab) async -> [Frame] {
    var frames: [Frame] = []
    for (id, info) in tab.agentFrames.sorted(by: { $0.key < $1.key }) where !info.isMainFrame {
      guard let url = await currentURL(tab, frameID: id, info: info) else { continue }
      frames.append(Frame(id: id, info: info, url: url))
    }
    return frames
  }

  static func frameURL(_ tab: BrowserTab, handle: String) async throws -> URL {
    let frameID = try checkedFrameID(tab, handle: handle)
    guard let frameID else {
      guard let url = tab.committedURL else { throw AgentFailure(message: "网页已关闭。") }
      return url
    }
    guard let info = tab.agentFrames[frameID],
      let url = await currentURL(tab, frameID: frameID, info: info) else {
      throw AgentFailure(message: "嵌入页面已变化，请重新检查网页。")
    }
    return url
  }

  private static func currentURL(_ tab: BrowserTab, frameID: String,
    info: WKFrameInfo) async -> URL? {
    guard let value = try? await tab.view.callAsyncJavaScript("""
      return { id: globalThis.__shipiosAgentFrameID || '', url: location.href };
      """, arguments: [:], in: info, contentWorld: world),
      let data = value as? [String: String], data["id"] == frameID,
      let raw = data["url"], let url = try? BrowserAddress.url(raw) else { return nil }
    return url
  }

  private static func checkedFrameID(_ tab: BrowserTab, handle: String) throws -> String? {
    let parts = handle.split(separator: ":", omittingEmptySubsequences: false)
    guard (parts.count == 2 || parts.count == 3),
      String(parts[0]) == tab.agentScanID else {
      throw AgentFailure(message: "元素句柄已过期，请重新检查网页。")
    }
    return parts.count == 3 ? String(parts[1]) : nil
  }

  static func inspect(_ tab: BrowserTab, frames: [Frame] = []) async throws -> JSONValue {
    let scanID = UUID().uuidString
    tab.agentScanID = scanID
    let script = """
      if (globalThis.__shipiosAgentFrameID !== expectedFrameID || location.href !== expectedURL)
        throw new Error('页面已变化，请重新检查网页。');
      const candidates = Array.from(document.querySelectorAll(
        'a[href], button, input:not([type="hidden"]), textarea, select, [role="button"], [contenteditable="true"]'));
      const visible = element => {
        const style = getComputedStyle(element);
        return element.isConnected && element.getClientRects().length > 0
          && style.display !== 'none' && style.visibility !== 'hidden';
      };
      const visibleNodes = candidates.filter(visible);
      const nodes = visibleNodes.slice(0, limit);
      globalThis.__shipiosAgentScan = { id: scanID, frameID, url: location.href, nodes };
      const elements = nodes.map((element, index) => {
        const label = element.getAttribute('aria-label') || element.labels?.[0]?.innerText
          || element.innerText || element.getAttribute('placeholder') || element.getAttribute('name') || '';
        return {
          handle: scanID + ':' + (frameID ? frameID + ':' : '') + index,
          tag: element.tagName.toLowerCase(),
          role: element.getAttribute('role') || '',
          type: element.getAttribute('type') || '',
          label: String(label).trim().slice(0, 120),
          href: element.href ? String(element.href).slice(0, 256) : '',
          frame_url: location.href
        };
      });
      return { elements, truncated: visibleNodes.length > nodes.length };
      """
    func scan(_ frame: WKFrameInfo?, id: String, expectedFrameID: String,
      url: URL, limit: Int) async throws -> JSONValue {
      let value = try await tab.view.callAsyncJavaScript(script,
        arguments: ["scanID": scanID, "frameID": id, "expectedFrameID": expectedFrameID,
          "expectedURL": url.absoluteString, "limit": limit], in: frame, contentWorld: world)
      guard let value else { throw AgentFailure(message: "无法检查网页控件。") }
      return try json(value)
    }
    guard let mainURL = tab.committedURL else { throw AgentFailure(message: "网页已关闭。") }
    let mainFrameID = try await tab.view.callAsyncJavaScript(
      "return globalThis.__shipiosAgentFrameID || '';", arguments: [:], in: nil, contentWorld: world)
      as? String ?? ""
    let main = try await scan(nil, id: "", expectedFrameID: mainFrameID, url: mainURL, limit: 50)
    var elements = main["elements"].items
    var truncated = main["truncated"].boolean == true
    for frame in frames {
      let remaining = 50 - elements.count
      if remaining == 0 { truncated = true; break }
      guard let current = await currentURL(tab, frameID: frame.id, info: frame.info),
        current == frame.url,
        let result = try? await scan(frame.info, id: frame.id, expectedFrameID: frame.id, url: frame.url,
          limit: remaining) else { continue }
      elements.append(contentsOf: result["elements"].items)
      truncated = truncated || result["truncated"].boolean == true
    }
    return .object(["elements": .array(elements), "truncated": .bool(truncated)])
  }

  static func target(_ tab: BrowserTab, handle: String) async throws -> JSONValue {
    let frameID = try checkedFrameID(tab, handle: handle)
    let frame = frameID.flatMap { tab.agentFrames[$0] }
    if frameID != nil && frame == nil {
      throw AgentFailure(message: "嵌入页面已变化，请重新检查网页。")
    }
    let value = try await tab.view.callAsyncJavaScript("""
      const state = globalThis.__shipiosAgentScan;
      const parts = handle.split(':');
      const slot = parts[parts.length - 1];
      const index = Number(slot);
      if (!state || (parts.length !== 2 && parts.length !== 3) || parts[0] !== state.id
          || state.frameID !== frameID || (parts.length === 3 && parts[1] !== frameID)
          || !/^(0|[1-9][0-9]*)$/.test(slot) || state.url !== location.href
          || !Number.isInteger(index) || index < 0 || index >= state.nodes.length)
        throw new Error('元素句柄已过期，请重新检查网页。');
      const element = state.nodes[index];
      const style = getComputedStyle(element);
      if (!element.isConnected || element.getClientRects().length === 0
          || style.display === 'none' || style.visibility === 'hidden')
        throw new Error('元素已消失，请重新检查网页。');
      const label = element.getAttribute('aria-label') || element.labels?.[0]?.innerText
        || element.innerText || element.getAttribute('placeholder') || '';
      return { tag: element.tagName.toLowerCase(), type: element.getAttribute('type') || '',
        role: element.getAttribute('role') || '', label: String(label).trim().slice(0, 120),
        href: element.href || '', target: element.getAttribute('target') || '',
        disabled: !!element.disabled, frame_url: location.href };
      """, arguments: ["handle": handle, "frameID": frameID ?? ""],
      in: frame, contentWorld: world)
    guard let value else { throw AgentFailure(message: "网页元素已不可用。") }
    return try json(value)
  }

  static func perform(_ tab: BrowserTab, action: String, handle: String,
    text: String? = nil) async throws {
    let frameID = try checkedFrameID(tab, handle: handle)
    let frame = frameID.flatMap { tab.agentFrames[$0] }
    if frameID != nil && frame == nil {
      throw AgentFailure(message: "嵌入页面已变化，请重新检查网页。")
    }
    _ = try await tab.view.callAsyncJavaScript("""
      const state = globalThis.__shipiosAgentScan;
      const parts = handle.split(':');
      const slot = parts[parts.length - 1];
      const index = Number(slot);
      if (!state || (parts.length !== 2 && parts.length !== 3) || parts[0] !== state.id
          || state.frameID !== frameID || (parts.length === 3 && parts[1] !== frameID)
          || !/^(0|[1-9][0-9]*)$/.test(slot) || state.url !== location.href
          || !Number.isInteger(index) || index < 0 || index >= state.nodes.length)
        throw new Error('元素句柄已过期，请重新检查网页。');
      const element = state.nodes[index];
      const style = getComputedStyle(element);
      if (!element.isConnected || element.getClientRects().length === 0
          || style.display === 'none' || style.visibility === 'hidden' || element.disabled)
        throw new Error('元素不可操作，请重新检查网页。');
      if (action === 'click') {
        element.click();
      } else if (action === 'fill') {
        const tag = element.tagName.toLowerCase();
        const type = (element.getAttribute('type') || 'text').toLowerCase();
        if (tag === 'input') {
          if (!['text', 'search', 'email', 'url', 'tel', 'number'].includes(type))
            throw new Error('此输入类型不可由 Agent 填写。');
          const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
          setter.call(element, text);
        } else if (tag === 'textarea') {
          const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set;
          setter.call(element, text);
        } else if (tag === 'select') {
          const option = Array.from(element.options).find(item => item.value === text || item.text === text);
          if (!option) throw new Error('下拉选项不存在。');
          element.value = option.value;
        } else if (element.isContentEditable) {
          element.textContent = text;
        } else {
          throw new Error('此元素不是可填写的输入框。');
        }
        element.dispatchEvent(new Event('input', { bubbles: true }));
        element.dispatchEvent(new Event('change', { bubbles: true }));
      }
      """, arguments: ["action": action, "handle": handle, "frameID": frameID ?? "",
        "text": text ?? ""], in: frame, contentWorld: world)
  }

  private static func json(_ value: Any) throws -> JSONValue {
    let data = try JSONSerialization.data(withJSONObject: value)
    return try JSONDecoder().decode(JSONValue.self, from: data)
  }
}
