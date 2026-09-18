import Foundation

enum ShipiOSDeepLink: Equatable {
  case workspace
  case projects
  case plugins
  case automations
  case settings(SettingsPage?)
  case task(String)

  init?(url: URL) {
    guard url.scheme?.lowercased() == "shipios", url.user == nil, url.password == nil,
      let host = url.host?.lowercased()
    else { return nil }
    let parts = url.pathComponents.filter { $0 != "/" }
    switch host {
    case "workspace": self = .workspace
    case "projects": self = .projects
    case "plugins": self = .plugins
    case "automations": self = .automations
    case "settings":
      guard parts.count <= 1 else { return nil }
      if let raw = parts.first {
        guard let page = SettingsPage(rawValue: raw) else { return nil }
        self = .settings(page)
      } else { self = .settings(nil) }
    case "task":
      guard parts.count == 1, let decoded = parts[0].removingPercentEncoding,
        !decoded.isEmpty, decoded.utf8.count <= 200,
        decoded.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
      else { return nil }
      self = .task(decoded)
    default: return nil
    }
  }

  var url: URL? {
    switch self {
    case .workspace: return URL(string: "shipios://workspace")
    case .projects: return URL(string: "shipios://projects")
    case .plugins: return URL(string: "shipios://plugins")
    case .automations: return URL(string: "shipios://automations")
    case .settings(let page):
      return URL(string: "shipios://settings" + (page.map { "/\($0.rawValue)" } ?? ""))
    case .task(let id):
      guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
      return URL(string: "shipios://task/\(encoded)")
    }
  }
}
