import Foundation

/// Stable identities for external document URLs used by the Codex Sources panel.
enum TaskExternalResourceIdentity {
  static func canonicalKey(_ raw: String) -> String? {
    guard let url = try? BrowserAddress.url(raw), let host = url.host?.lowercased() else { return nil }
    let path = url.path.split(separator: "/").map(String.init)
    if ["docs.google.com", "sheets.google.com", "slides.google.com"].contains(host),
      path.count >= 3, path[1] == "d", ["document", "spreadsheets", "presentation"].contains(path[0]) {
      let identifier = path[2] == "e" && path.count > 3 ? path[3] : path[2]
      let kind = path[0] == "spreadsheets" ? "spreadsheet" : path[0]
      return identifier.isEmpty ? nil : "google:\(kind):\(identifier)"
    }
    if host == "drive.google.com" {
      let identifier: String? = path.count >= 3 && path[0] == "file" && path[1] == "d"
        ? path[2] : path.count >= 3 && path[0] == "drive" && path[1] == "folders"
          ? path[2] : URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "id" })?.value
      return identifier.flatMap { $0.isEmpty ? nil : "google:drive:\($0)" }
    }
    if host == "notion.so" || host.hasSuffix(".notion.so") || host == "app.notion.com" {
      let expression = try? NSRegularExpression(
        pattern: "[0-9a-f]{32}|[0-9a-f]{8}-[0-9a-f-]{27}", options: .caseInsensitive)
      let range = NSRange(url.path.startIndex..<url.path.endIndex, in: url.path)
      guard let match = expression?.matches(in: url.path, range: range).last,
        let matchRange = Range(match.range, in: url.path) else { return nil }
      return "notion:\(url.path[matchRange].replacingOccurrences(of: "-", with: "").lowercased())"
    }
    if host == "linear.app", path.count >= 3,
      ["issue", "project", "document"].contains(path[1]) {
      return "linear:\(path[0].lowercased()):\(path[1]):\(path[2])"
    }
    if host == "figma.com" || host.hasSuffix(".figma.com"), path.count >= 2,
      ["board", "design", "file", "make", "proto", "slides"].contains(path[0]) {
      return "figma:\(path[1])"
    }
    return nil
  }
}
