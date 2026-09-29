import Foundation

extension GitHubPRCodeFile {
  var headerRelativePath: String { path.replacingOccurrences(of: "\\", with: "/") }
  var headerPaths: [String] {
    if kind == .renamed, let oldPath, oldPath != path {
      return [oldPath.replacingOccurrences(of: "\\", with: "/"), headerRelativePath]
    }
    return [headerRelativePath]
  }
  var headerFilename: String { headerPaths.map { $0.split(separator: "/").last.map(String.init) ?? $0 }.joined(separator: " → ") }
  var headerDescription: String { headerPaths.joined(separator: " → ") }
}
