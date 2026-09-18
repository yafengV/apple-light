import Foundation

enum MessageLink {
  enum Target: Equatable {
    case web(URL)
    case file(path: String, line: Int?)
  }

  static func url(_ value: String) -> URL? {
    guard !value.isEmpty else { return nil }
    var value = value
    if !value.contains("://"), let colon = value.lastIndex(of: ":"),
      Int(value[value.index(after: colon)...]) != nil,
      !value[..<colon].contains(":")
    {
      value = String(value[..<colon]) + "%3A" + value[value.index(after: colon)...]
    }
    let allowed = CharacterSet(
      charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")
    return value.addingPercentEncoding(withAllowedCharacters: allowed).flatMap { URL(string: $0) }
  }

  static func target(_ url: URL, root: URL?) throws -> Target {
    if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
      return .web(url)
    }
    guard let root else { throw AgentFailure(message: "此会话没有项目目录，无法打开文件链接。") }
    guard url.scheme == nil || url.isFileURL else {
      throw AgentFailure(message: "不支持此链接类型。")
    }
    guard url.host == nil || url.host == "" || url.host == "localhost" else {
      throw AgentFailure(message: "不支持远程文件链接。")
    }
    var path = url.path
    var line: Int?
    if let fragment = url.fragment, fragment.hasPrefix("L") {
      line = Int(fragment.dropFirst().prefix(while: { $0.isNumber }))
    }
    if let colon = path.lastIndex(of: ":"), let value = Int(path[path.index(after: colon)...]) {
      line = value
      path = String(path[..<colon])
    }
    guard line == nil || line! > 0 else { throw AgentFailure(message: "文件行号必须大于零。") }
    let base = root.resolvingSymlinksInPath().standardizedFileURL
    let candidate =
      path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
    let file = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
      .appendingPathComponent(candidate.lastPathComponent).resolvingSymlinksInPath()
      .standardizedFileURL
    guard file.path.hasPrefix(base.path + "/") else {
      throw AgentFailure(message: "链接文件不在当前项目目录内。")
    }
    return .file(path: String(file.path.dropFirst(base.path.count + 1)), line: line)
  }
}
