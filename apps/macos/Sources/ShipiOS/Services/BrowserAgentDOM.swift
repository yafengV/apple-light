import Foundation
import WebKit

/// Browser elements are kept in an isolated JavaScript world, scoped to one document scan.
@MainActor
enum BrowserAgentDOM {
  private static let world = WKContentWorld.world(name: "ShipiOS.Agent")

  static func inspect(_ tab: BrowserTab) async throws -> JSONValue {
    let scanID = UUID().uuidString
    let value = try await tab.view.callAsyncJavaScript("""
      const candidates = Array.from(document.querySelectorAll(
        'a[href], button, input:not([type="hidden"]), textarea, select, [role="button"], [contenteditable="true"]'));
      const visible = element => {
        const style = getComputedStyle(element);
        return element.isConnected && element.getClientRects().length > 0
          && style.display !== 'none' && style.visibility !== 'hidden';
      };
      const visibleNodes = candidates.filter(visible);
      const nodes = visibleNodes.slice(0, 50);
      globalThis.__shipiosAgentScan = { id: scanID, url: location.href, nodes };
      const elements = nodes.map((element, index) => {
        const label = element.getAttribute('aria-label') || element.labels?.[0]?.innerText
          || element.innerText || element.getAttribute('placeholder') || element.getAttribute('name') || '';
        return {
          handle: scanID + ':' + index,
          tag: element.tagName.toLowerCase(),
          role: element.getAttribute('role') || '',
          type: element.getAttribute('type') || '',
          label: String(label).trim().slice(0, 120),
          href: element.href ? String(element.href).slice(0, 256) : ''
        };
      });
      return { elements, truncated: visibleNodes.length > nodes.length };
      """, arguments: ["scanID": scanID], in: nil, contentWorld: world)
    guard let value else { throw AgentFailure(message: "无法检查网页控件。") }
    return try json(value)
  }

  static func target(_ tab: BrowserTab, handle: String) async throws -> JSONValue {
    let value = try await tab.view.callAsyncJavaScript("""
      const state = globalThis.__shipiosAgentScan;
      const parts = handle.split(':');
      const index = Number(parts[1]);
      if (!state || parts.length !== 2 || parts[0] !== state.id
          || !/^(0|[1-9][0-9]*)$/.test(parts[1]) || state.url !== location.href
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
        disabled: !!element.disabled };
      """, arguments: ["handle": handle], in: nil, contentWorld: world)
    guard let value else { throw AgentFailure(message: "网页元素已不可用。") }
    return try json(value)
  }

  static func perform(_ tab: BrowserTab, action: String, handle: String,
    text: String? = nil) async throws {
    _ = try await tab.view.callAsyncJavaScript("""
      const state = globalThis.__shipiosAgentScan;
      const parts = handle.split(':');
      const index = Number(parts[1]);
      if (!state || parts.length !== 2 || parts[0] !== state.id
          || !/^(0|[1-9][0-9]*)$/.test(parts[1]) || state.url !== location.href
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
      """, arguments: ["action": action, "handle": handle, "text": text ?? ""],
      in: nil, contentWorld: world)
  }

  private static func json(_ value: Any) throws -> JSONValue {
    let data = try JSONSerialization.data(withJSONObject: value)
    return try JSONDecoder().decode(JSONValue.self, from: data)
  }
}
