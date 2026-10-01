import ApplicationServices
import Foundation

enum AppshotAccessibility {
  static func snapshot(pid: pid_t?, windowTitle: String?) async -> String {
    guard let pid, let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
      !title.isEmpty, AXIsProcessTrusted() else { return "" }
    return await Task.detached(priority: .utility) {
      collect(pid: pid, title: title)
    }.value
  }

  private static func collect(pid: pid_t, title: String) -> String {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.1)
    let windows = children(app, attribute: kAXWindowsAttribute as CFString).prefix(30)
      .filter { string($0, attribute: kAXTitleAttribute as CFString) == title }
    guard windows.count == 1 else { return "" }
    var lines: [String] = []
    var bytes = 0
    var nodes = 0
    let deadline = Date().addingTimeInterval(1.5)
    func visit(_ element: AXUIElement, depth: Int) {
      guard depth <= 5, nodes < 120, bytes < 24_000, Date() < deadline else { return }
      nodes += 1
      AXUIElementSetMessagingTimeout(element, 0.1)
      let role = string(element, attribute: kAXRoleAttribute as CFString) ?? ""
      let subrole = string(element, attribute: kAXSubroleAttribute as CFString) ?? ""
      let secure = role.localizedCaseInsensitiveContains("secure")
        || subrole.localizedCaseInsensitiveContains("secure")
      let fields = [role, subrole,
        string(element, attribute: kAXTitleAttribute as CFString) ?? "",
        string(element, attribute: kAXDescriptionAttribute as CFString) ?? "",
        secure ? "" : string(element, attribute: kAXValueAttribute as CFString) ?? ""]
        .filter { !$0.isEmpty }
        .map { String($0.prefix(512)).replacingOccurrences(of: "\n", with: " ") }
      if !fields.isEmpty {
        let line = String(repeating: "  ", count: depth) + fields.joined(separator: " | ")
        let remaining = 24_000 - bytes
        let clipped = String(decoding: Data(line.utf8).prefix(remaining), as: UTF8.self)
        lines.append(clipped)
        bytes += clipped.utf8.count + 1
      }
      for child in children(element, attribute: kAXChildrenAttribute as CFString).prefix(20) {
        visit(child, depth: depth + 1)
      }
    }
    visit(windows[0], depth: 0)
    return lines.joined(separator: "\n")
  }

  private static func string(_ element: AXUIElement, attribute: CFString) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
    return value as? String
  }

  private static func children(_ element: AXUIElement, attribute: CFString) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return [] }
    return value as? [AXUIElement] ?? []
  }
}
