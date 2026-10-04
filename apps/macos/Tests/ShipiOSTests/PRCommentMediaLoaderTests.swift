import Foundation
import XCTest
@testable import ShipiOS

/// Only the injected test session uses this protocol. No real GitHub request or
/// account token is used by these loader integration tests.
private final class PRMediaFixtureProtocol: URLProtocol {
  struct Reply { var data: Data; var mime = "image/png"; var status = 200; var length: Int? }
  private static let lock = NSLock()
  private static var reply = Reply(data: Data([1]))
  private static var requests: [URLRequest] = []
  static func configure(_ value: Reply) { lock.lock(); defer { lock.unlock() }; reply = value; requests = [] }
  static func observedRequests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
  override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "github.com" }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.lock.lock(); let reply = Self.reply; Self.requests.append(request); Self.lock.unlock()
    var headers = ["Content-Type": reply.mime]
    if let length = reply.length { headers["Content-Length"] = String(length) }
    let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    for start in stride(from: 0, to: reply.data.count, by: 32768) {
      client?.urlProtocol(self, didLoad: reply.data.subdata(in: start..<min(start + 32768, reply.data.count)))
    }
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

final class PRCommentMediaLoaderTests: XCTestCase {
  private func session() -> URLSession {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PRMediaFixtureProtocol.self]
    return URLSession(configuration: config)
  }
  private var media: GitHubPRCommentMedia {
    .init(url: URL(string: "https://github.com/user-attachments/assets/fixture")!, kind: .image, alt: "Fixture")
  }
  func testInjectedSessionUsesFakeTokenAndReturnsNormalizedResponseMIMEAndBytes() async throws {
    let bytes = Data([1, 2, 3, 4]), session = session(); defer { session.invalidateAndCancel() }
    PRMediaFixtureProtocol.configure(.init(data: bytes, mime: "IMAGE/PNG; charset=binary", length: 4))
    let result = try await GitHubPRCommentMediaLoader.load(media, session: session, tokenProvider: { "fake-token" })
    XCTAssertEqual(result.data, bytes); XCTAssertEqual(result.mimeType, "image/png")
    let request = try XCTUnwrap(PRMediaFixtureProtocol.observedRequests().first)
    XCTAssertEqual(request.url, media.url); XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-token")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/octet-stream")
  }
  func testHTTPFailureWrongMIMEEmptyBodyAndOversizedHeaderAreRejected() async throws {
    let session = session(); defer { session.invalidateAndCancel() }
    for reply in [PRMediaFixtureProtocol.Reply(data: Data([1]), status: 404),
      .init(data: Data([1]), mime: "text/html"), .init(data: Data()),
      .init(data: Data([1]), length: GitHubPRCommentMediaLoader.maximumBytes + 1)] {
      PRMediaFixtureProtocol.configure(reply)
      do {
        _ = try await GitHubPRCommentMediaLoader.load(media, session: session, tokenProvider: { nil })
        XCTFail("Invalid media response was accepted")
      } catch { XCTAssertTrue(error is AgentFailure) }
    }
  }
  func testUnknownLengthStreamAcceptsExactLimitAndRejectsOneAdditionalByte() async throws {
    let session = session(); defer { session.invalidateAndCancel() }
    let bytes = Data(repeating: 1, count: GitHubPRCommentMediaLoader.maximumBytes)
    PRMediaFixtureProtocol.configure(.init(data: bytes))
    let payload = try await GitHubPRCommentMediaLoader.load(media, session: session, tokenProvider: { nil })
    XCTAssertEqual(payload.data.count, bytes.count)
    PRMediaFixtureProtocol.configure(.init(data: bytes + Data([1])))
    do {
      _ = try await GitHubPRCommentMediaLoader.load(media, session: session, tokenProvider: { nil })
      XCTFail("A streamed body exceeding the byte limit must not be returned")
    } catch { XCTAssertTrue(error is AgentFailure) }
  }
  func testCancellationBeforeRequestNeverUsesInjectedSession() async throws {
    let session = session(); defer { session.invalidateAndCancel() }
    PRMediaFixtureProtocol.configure(.init(data: Data([1])))
    let task = Task { [media] in
      try await GitHubPRCommentMediaLoader.load(media, session: session, tokenProvider: {
        try? await Task.sleep(for: .milliseconds(30)); return nil
      })
    }
    task.cancel()
    do { _ = try await task.value; XCTFail("Cancelled request succeeded") } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertTrue(PRMediaFixtureProtocol.observedRequests().isEmpty)
  }
}
