import Foundation

private final class GitHubPRMediaRedirectDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void) {
    guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
      parts.port == nil, let host = parts.host?.lowercased(),
      host == "github.com" || host == "githubusercontent.com" ||
        host.hasSuffix(".githubusercontent.com") else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }
}

enum GitHubPRCommentMediaLoader {
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
    let limit = media.kind == .image ? 24 * 1_048_576 : 64 * 1_048_576
    let options = URLSessionConfiguration.ephemeral
    options.timeoutIntervalForRequest = 20
    options.timeoutIntervalForResource = 60
    options.httpShouldSetCookies = false
    options.urlCache = nil
    let session = URLSession(configuration: options, delegate: GitHubPRMediaRedirectDelegate(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: media.url)
    request.setValue("image/*, video/*, application/octet-stream", forHTTPHeaderField: "Accept")
    let (bytes, response) = try await session.bytes(for: request)
    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
      accepts(response.value(forHTTPHeaderField: "Content-Type"), kind: media.kind),
      response.expectedContentLength < 0 || response.expectedContentLength <= limit else {
      throw AgentFailure(message: "GitHub 媒体预览不可用。")
    }
    var data = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      guard data.count < limit else { throw AgentFailure(message: "GitHub 媒体超过预览大小限制。") }
      data.append(byte)
    }
    guard !data.isEmpty else { throw AgentFailure(message: "GitHub 媒体为空。") }
    return data
  }
}
