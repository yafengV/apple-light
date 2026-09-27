import Foundation

enum CopyLocationTarget: Equatable {
  case browser(URL)
  case directory(String)

  static func resolve(browserFocused: Bool, browserURL: URL?, workingDirectory: String?) -> Self? {
    if browserFocused { return browserURL.map(Self.browser) }
    guard let workingDirectory, workingDirectory.hasPrefix("/") else { return nil }
    return .directory(workingDirectory)
  }

  var text: String {
    switch self {
    case .browser(let url): url.absoluteString
    case .directory(let path): path
    }
  }

  var menuTitle: String {
    switch self {
    case .browser: "复制浏览器网址"
    case .directory: "复制工作目录"
    }
  }
}
