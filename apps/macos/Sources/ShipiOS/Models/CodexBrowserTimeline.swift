import Foundation

/// Keeps one visible timeline row for each native browser request and its reply.
enum CodexBrowserTimeline {
  static let serverID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

  static func apply(_ event: JSONValue, executions: inout [MCPToolExecution],
    items: inout [ChatResponseItem]) -> Bool {
    guard let type = event["type"].text,
      ["browser_request", "browser_result"].contains(type),
      let requestID = event["requestId"].text, UUID(uuidString: requestID) != nil else { return false }
    let index = executions.firstIndex { $0.serverID == serverID && $0.callID == requestID }
    guard type == "browser_request" || index != nil else { return false }
    let action = event["action"].text ?? ""
    let name: String = switch action {
    case "open": "打开网页"
    case "read": "读取网页"
    case "screenshot": "截取网页"
    case "inspect": "检查网页控件"
    case "click": "点击网页控件"
    case "fill": "填写网页控件"
    default: "列出网页标签"
    }
    var execution = index.map { executions[$0] } ?? MCPToolExecution(
      callID: requestID, serverID: serverID, serverName: "浏览器", toolName: name,
      arguments: event["url"].text ?? event["tabId"].text ?? "当前任务",
      status: .running)
    if type == "browser_result" {
      let result = event["result"]
      execution.status = switch result["status"].text {
      case "ok", "loading": .succeeded
      case "denied": .denied
      case "cancelled": .cancelled
      default: .failed
      }
      execution.output = String(result.pretty.prefix(16_000))
      if let url = result["url"].text {
        let label = result["label"].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        execution.arguments = label.isEmpty ? url : "\(label) · \(url)"
      }
    }
    if let index { executions[index] = execution }
    else {
      executions.append(execution)
      items.append(.tool(execution.id))
    }
    return true
  }

  static func source(_ event: JSONValue) -> CodexWebSource? {
    guard event["type"].text == "browser_result",
      event["result"]["status"].text == "ok",
      let raw = event["result"]["url"].text, raw.utf8.count <= 4_096,
      let url = try? BrowserAddress.url(raw) else { return nil }
    let title = event["result"]["title"].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return CodexWebSource(title: title.isEmpty ? url.host ?? url.absoluteString : String(title.prefix(160)),
      url: url.absoluteString)
  }

  static func expirePending(_ executions: inout [MCPToolExecution],
    status: MCPToolExecution.Status) -> Bool {
    var changed = false
    for index in executions.indices where executions[index].serverID == serverID
      && executions[index].status == .running {
      executions[index].status = status
      changed = true
    }
    return changed
  }
}
