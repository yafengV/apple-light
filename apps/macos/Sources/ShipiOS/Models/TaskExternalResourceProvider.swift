import Foundation

struct TaskExternalResourceProvider: Equatable {
  let id: String
  let name: String

  static func identify(_ raw: String) -> Self? {
    guard let url = try? BrowserAddress.url(raw), let host = url.host?.lowercased() else { return nil }
    if ["docs.google.com", "drive.google.com", "sheets.google.com", "slides.google.com"].contains(host) {
      return Self(id: "google-drive", name: "Google Drive")
    }
    if host == "notion.so" || host.hasSuffix(".notion.so") || host == "app.notion.com" {
      return Self(id: "notion", name: "Notion")
    }
    if host == "linear.app" { return Self(id: "linear", name: "Linear") }
    if host == "figma.com" || host.hasSuffix(".figma.com") {
      return Self(id: "figma", name: "Figma")
    }
    if host == "github.com" || host.hasSuffix(".github.com") {
      return Self(id: "github", name: "GitHub")
    }
    return nil
  }
}
