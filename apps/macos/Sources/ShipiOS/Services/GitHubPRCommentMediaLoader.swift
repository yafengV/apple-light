import Foundation

private final class GitHubPRMediaRedirectDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(GitHubPRMediaRequestPolicy.redirect(request,
      originalHost: task.originalRequest?.url?.host))
  }
}

enum GitHubPRMediaRequestPolicy {
  static func redirect(_ request: URLRequest, originalHost: String?) -> URLRequest? {
    guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
      parts.port == nil, let host = parts.host?.lowercased(),
      host == "github.com" || host == "githubusercontent.com" ||
        host.hasSuffix(".githubusercontent.com") else {
      return nil
    }
    var safeRequest = request
    if host != originalHost?.lowercased() {
      safeRequest.setValue(nil, forHTTPHeaderField: "Authorization")
    }
    return safeRequest
  }
}

enum GitHubPRCommentMediaLoader {
  static let maximumBytes = 10 * 1_048_576

  static func accepts(_ mimeType: String?, kind: GitHubPRCommentMedia.Kind) -> Bool {
    guard let mimeType else { return false }
    let type = mimeType.split(separator: ";", maxSplits: 1).first?
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    switch kind {
    case .image: return type.hasPrefix("image/") && type != "image/svg+xml"
    case .video: return type.hasPrefix("video/") || type == "application/octet-stream"
    }
  }

  static func load(_ media: GitHubPRCommentMedia) async throws -> Data {
    guard GitHubPRCommentMedia.allowedURL(media.url.absoluteString) != nil else {
      throw AgentFailure(message: "GitHub 媒体地址无效。")
    }
    let options = URLSessionConfiguration.ephemeral
    options.timeoutIntervalForRequest = 20
    options.timeoutIntervalForResource = 60
    options.httpShouldSetCookies = false
    options.urlCache = nil
    let session = URLSession(configuration: options, delegate: GitHubPRMediaRedirectDelegate(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let request = mediaRequest(media, token: await authenticationToken())
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
      accepts(response.value(forHTTPHeaderField: "Content-Type"), kind: media.kind),
      response.expectedContentLength < 0 || response.expectedContentLength <= maximumBytes else {
      throw AgentFailure(message: "GitHub 媒体预览不可用。")
    }
    var data = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      guard data.count < maximumBytes else { throw AgentFailure(message: "GitHub 媒体超过预览大小限制。") }
      data.append(byte)
    }
    guard !data.isEmpty else { throw AgentFailure(message: "GitHub 媒体为空。") }
    return data
  }

  static func mediaRequest(_ media: GitHubPRCommentMedia, token: String?) -> URLRequest {
    var request = URLRequest(url: media.url)
    request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
    if let token, validToken(token),
      GitHubPRCommentMedia.allowedURL(media.url.absoluteString) != nil {
      request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    }
    return request
  }

  static func authenticationToken(executable: URL? = GitHubPRService.installedExecutable()) async -> String? {
    guard let executable else { return nil }
    let root = FileManager.default.homeDirectoryForCurrentUser
    guard let result = try? await LocalWorkspaceService.command(executable.path,
      ["auth", "token", "--hostname", "github.com"], at: root, cancelWithTask: true),
      result.status == 0 else { return nil }
    let token = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    return validToken(token) ? token : nil
  }

  private static func validToken(_ token: String) -> Bool {
    !token.isEmpty && token.utf8.count <= 4096 && token.utf8.allSatisfy { (33...126).contains($0) }
  }
}
