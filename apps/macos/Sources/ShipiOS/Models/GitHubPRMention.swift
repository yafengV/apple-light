import Foundation

struct GitHubPRMentionUser: Equatable, Identifiable, Sendable {
  let login: String
  let avatarURL: String?
  var id: String { login.lowercased() }
}

struct GitHubPRMentionRequest: Equatable, Sendable {
  let pullRequest: GitHubPullRequest
  let root: URL
  let viewer: String
  var scope: String { root.standardizedFileURL.path + "\n" + pullRequest.url.lowercased() + "\n" + viewer.lowercased() }
}

struct GitHubPRMentionToken: Equatable, Sendable {
  let range: NSRange
  let query: String
  static func detect(text: String, selection: NSRange) -> Self? {
    let source = text as NSString
    guard selection.length == 0, selection.location != NSNotFound, selection.location <= source.length else { return nil }
    let prefix = source.substring(to: selection.location) as NSString
    let regex = try! NSRegularExpression(pattern: "(^|[^A-Za-z0-9_-])@([A-Za-z0-9_-]*)$")
    guard let match = regex.firstMatch(in: prefix as String, range: NSRange(location: 0, length: prefix.length)) else { return nil }
    let queryRange = match.range(at: 2), query = prefix.substring(with: queryRange)
    let start = queryRange.location - 1
    var end = selection.location
    while end < source.length, isLoginCharacter(source.character(at: end)) { end += 1 }
    return .init(range: NSRange(location: start, length: end - start), query: query)
  }
  static func isLoginCharacter(_ value: unichar) -> Bool {
    (65...90).contains(value) || (97...122).contains(value) || (48...57).contains(value) || value == 95 || value == 45
  }
  func replacement(login: String, in text: String) -> PullRequestTextReplacement? {
    let source = text as NSString
    guard !login.isEmpty, login.utf16.allSatisfy(Self.isLoginCharacter),
      range.location <= source.length, range.length <= source.length - range.location,
      source.substring(with: range).hasPrefix("@") else { return nil }
    let suffix = NSMaxRange(range) == source.length ? " " : ""
    return .init(expectedText: text, selection: .init(location: range.location + query.utf16.count + 1, length: 0),
      range: range, text: "@" + login + suffix)
  }
}

struct PullRequestTextReplacement: Equatable, Sendable {
  let id = UUID()
  let expectedText: String
  let selection: NSRange
  let range: NSRange
  let text: String
}
