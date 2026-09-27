import Foundation

enum ShipiOSDeepLink: Equatable {
  case workspace
  case projects
  case plugins
  case automations
  case automationsList
  case newTask(prompt: String?, path: String?, originURL: String?)
  case settings(SettingsPage?)
  case task(String)

  init?(url: URL) {
    guard url.scheme?.lowercased() == "shipios", url.user == nil, url.password == nil,
      url.port == nil, url.fragment == nil,
      let host = url.host?.lowercased()
    else { return nil }
    let parts = url.pathComponents.filter { $0 != "/" }
    switch host {
    case "workspace": self = .workspace
    case "projects": self = .projects
    case "plugins": self = .plugins
    case "automations":
      if parts.isEmpty { self = .automations }
      else if parts == ["list"] { self = .automationsList }
      else { return nil }
    case "threads", "new":
      guard (host == "threads" && parts == ["new"]) || (host == "new" && parts.isEmpty),
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
      var parameters: [String: String] = [:]
      for item in components.queryItems ?? [] {
        guard ["prompt", "path", "originUrl"].contains(item.name),
          let value = item.value, parameters.updateValue(value, forKey: item.name) == nil
        else { return nil }
      }
      guard host != "new" || !parameters.isEmpty,
        (parameters["prompt"]?.utf8.count ?? 0) <= 20_000,
        (parameters["path"]?.utf8.count ?? 0) <= 4096,
        (parameters["originUrl"]?.utf8.count ?? 0) <= 4096
      else { return nil }
      self = .newTask(prompt: parameters["prompt"], path: parameters["path"],
        originURL: parameters["originUrl"])
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
    case .automationsList: return URL(string: "shipios://automations/list")
    case .newTask(let prompt, let path, let originURL):
      var components = URLComponents(string: "shipios://threads/new")
      components?.queryItems = [
        prompt.map { URLQueryItem(name: "prompt", value: $0) },
        path.map { URLQueryItem(name: "path", value: $0) },
        originURL.map { URLQueryItem(name: "originUrl", value: $0) },
      ].compactMap { $0 }
      if components?.queryItems?.isEmpty == true { components?.queryItems = nil }
      return components?.url
    case .settings(let page):
      return URL(string: "shipios://settings" + (page.map { "/\($0.rawValue)" } ?? ""))
    case .task(let id):
      guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
      return URL(string: "shipios://task/\(encoded)")
    }
  }
}
