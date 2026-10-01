import ApplicationServices
import Foundation

struct AppshotAccessibilitySnapshot: Sendable {
  let text: String
  let windowTitle: String?

  static let empty = Self(text: "", windowTitle: nil)
}

enum AppshotAccessibility {
  struct WindowCandidate {
    let title: String?
    let frame: CGRect?
  }

  static func snapshot(pid: pid_t?, windowTitle: String?, windowFrame: CGRect?) async
    -> AppshotAccessibilitySnapshot {
    guard let pid, AXIsProcessTrusted() else { return .empty }
    let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard title?.isEmpty == false || windowFrame != nil else { return .empty }
    let task = Task.detached(priority: .utility) {
      collect(pid: pid, title: title, frame: windowFrame)
    }
    return await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
  }

  static func selectedIndex(_ windows: [WindowCandidate], title: String?, frame: CGRect?) -> Int? {
    let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    let exact = windows.indices.filter { index in
      title?.isEmpty == false && windows[index].title == title
    }
    if exact.count == 1 {
      let index = exact[0]
      guard let frame, let candidateFrame = windows[index].frame else { return index }
      if overlap(frame, candidateFrame) >= 0.5 { return index }
    }
    guard let frame, frame.width > 0, frame.height > 0 else { return nil }
    let pool = exact.count > 1 ? exact : Array(windows.indices)
    let ranked = pool.compactMap { index -> (Int, CGFloat)? in
      guard let candidateFrame = windows[index].frame else { return nil }
      return (index, overlap(frame, candidateFrame))
    }.sorted { $0.1 > $1.1 }
    guard let best = ranked.first, best.1 >= 0.72,
      ranked.count == 1 || best.1 - ranked[1].1 >= 0.1 else { return nil }
    return best.0
  }

  private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
    guard a.width > 0, a.height > 0, b.width > 0, b.height > 0,
      a.minX.isFinite, a.minY.isFinite, b.minX.isFinite, b.minY.isFinite else { return 0 }
    let intersection = a.intersection(b)
    guard !intersection.isNull else { return 0 }
    let area = intersection.width * intersection.height
    return area / (a.width * a.height + b.width * b.height - area)
  }

  private static func collect(pid: pid_t, title: String?, frame windowFrame: CGRect?)
    -> AppshotAccessibilitySnapshot {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.1)
    let windows = Array(children(app, attribute: kAXWindowsAttribute as CFString).prefix(30))
    let deadline = Date().addingTimeInterval(1.5)
    var candidates: [WindowCandidate] = []
    for window in windows {
      guard !Task.isCancelled, Date() < deadline else { break }
      AXUIElementSetMessagingTimeout(window, 0.1)
      candidates.append(WindowCandidate(
        title: string(window, attribute: kAXTitleAttribute as CFString), frame: frame(window)))
    }
    guard let index = selectedIndex(candidates, title: title, frame: windowFrame) else { return .empty }
    let window = windows[index]
    var lines: [String] = []
    var bytes = 0
    var nodes = 0
    func visit(_ element: AXUIElement, depth: Int) {
      guard !Task.isCancelled, depth <= 5, nodes < 120, bytes < 24_000,
        Date() < deadline else { return }
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
    visit(window, depth: 0)
    return AppshotAccessibilitySnapshot(text: lines.joined(separator: "\n"),
      windowTitle: candidates[index].title)
  }

  private static func frame(_ element: AXUIElement) -> CGRect? {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString,
        &positionValue) == .success,
      AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString,
        &sizeValue) == .success,
      let positionValue, let sizeValue,
      CFGetTypeID(positionValue) == AXValueGetTypeID(),
      CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
      AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: origin, size: size)
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
