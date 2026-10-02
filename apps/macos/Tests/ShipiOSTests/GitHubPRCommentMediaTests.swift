import XCTest
@testable import ShipiOS

final class GitHubPRCommentMediaTests: XCTestCase {
  func testOnlyGitHubMediaOriginsAndPathsAreEmbedded() {
    let allowed = [
      "https://github.com/user-attachments/assets/1234",
      "https://user-images.githubusercontent.com/1234/picture.png",
      "https://private-user-images.githubusercontent.com/1234/picture.png?jwt=example",
    ]
    XCTAssertTrue(allowed.allSatisfy { GitHubPRCommentMedia.allowedURL($0) != nil })
    let rejected = [
      "http://github.com/user-attachments/assets/1234",
      "https://github.com.evil.test/user-attachments/assets/1234",
      "https://user:pass@github.com/user-attachments/assets/1234",
      "https://github.com:444/user-attachments/assets/1234",
      "https://github.com/owner/repo/issues/1",
      "https://user-images.githubusercontent.com/",
      "https://user-images.githubusercontent.com/picture.png#fragment",
    ]
    XCTAssertTrue(rejected.allSatisfy { GitHubPRCommentMedia.allowedURL($0) == nil })
  }

  func testMarkdownImageAndVideoKeepSurroundingTextInOrder() {
    let source = "Before **bold** ![chart](https://user-images.githubusercontent.com/a.png) after.\n\n" +
      "https://github.com/user-attachments/assets/movie-id\n\nTail"
    let segments = GitHubPRCommentSegment.parse(source)
    XCTAssertEqual(segments.count, 5)
    guard case .markdown(let before) = segments[0], case .media(let image) = segments[1],
      case .markdown(let after) = segments[2], case .media(let video) = segments[3],
      case .markdown(let tail) = segments[4] else {
      return XCTFail("Expected text, image, text, video, text")
    }
    XCTAssertTrue(before.contains("**bold**"))
    XCTAssertEqual(image.kind, .image)
    XCTAssertEqual(image.alt, "chart")
    XCTAssertEqual(after, "after.")
    XCTAssertEqual(video.kind, .video)
    XCTAssertEqual(tail, "Tail")
  }

  func testCodeAndUntrustedImagesStayInMarkdown() {
    let source = "```md\n![fake](https://github.com/user-attachments/assets/id)\n```\n\n" +
      "![external](https://example.com/picture.png)"
    XCTAssertEqual(GitHubPRCommentSegment.parse(source), [.markdown(source)])
  }

  func testStandaloneHTMLMediaAndExtraHTML() {
    let image = "<img alt=\"chart\" src=\"https://user-images.githubusercontent.com/a.png\">"
    guard case .media(let item) = GitHubPRCommentSegment.parse(image).first else {
      return XCTFail("Expected HTML image")
    }
    XCTAssertEqual(item.kind, .image)
    let unsafe = image + "<script>alert(1)</script>"
    XCTAssertEqual(GitHubPRCommentSegment.parse(unsafe), [.markdown(unsafe)])
  }

  func testResponseMIMEIsCheckedBeforePreview() {
    XCTAssertTrue(GitHubPRCommentMediaLoader.accepts("image/png", kind: .image))
    XCTAssertFalse(GitHubPRCommentMediaLoader.accepts("image/svg+xml", kind: .image))
    XCTAssertFalse(GitHubPRCommentMediaLoader.accepts("text/html", kind: .image))
    XCTAssertTrue(GitHubPRCommentMediaLoader.accepts("video/mp4", kind: .video))
    XCTAssertTrue(GitHubPRCommentMediaLoader.accepts("application/octet-stream", kind: .video))
    XCTAssertFalse(GitHubPRCommentMediaLoader.accepts("text/html", kind: .video))
  }

  func testAuthenticatedRequestAndRedirectDoNotLeakToken() {
    let media = GitHubPRCommentMedia(url: URL(string: "https://github.com/user-attachments/assets/id")!,
      kind: .image, alt: "image")
    let request = GitHubPRCommentMediaLoader.mediaRequest(media, token: "fake-token")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-token")
    XCTAssertNil(GitHubPRCommentMediaLoader.mediaRequest(media, token: "bad\ntoken")
      .value(forHTTPHeaderField: "Authorization"))
    let external = GitHubPRCommentMedia(url: URL(string: "https://example.com/image.png")!,
      kind: .image, alt: "external")
    XCTAssertNil(GitHubPRCommentMediaLoader.mediaRequest(external, token: "fake-token")
      .value(forHTTPHeaderField: "Authorization"))
    var redirect = URLRequest(url: URL(string: "https://objects.githubusercontent.com/file")!)
    redirect.setValue("Bearer fake-token", forHTTPHeaderField: "Authorization")
    let accepted = GitHubPRMediaRequestPolicy.redirect(redirect, originalHost: "github.com")
    XCTAssertNotNil(accepted)
    XCTAssertNil(accepted?.value(forHTTPHeaderField: "Authorization"))
    redirect.url = URL(string: "https://example.com/file")!
    XCTAssertNil(GitHubPRMediaRequestPolicy.redirect(redirect, originalHost: "github.com"))
    redirect.url = URL(string: "http://objects.githubusercontent.com/file")!
    XCTAssertNil(GitHubPRMediaRequestPolicy.redirect(redirect, originalHost: "github.com"))
    XCTAssertEqual(GitHubPRCommentMediaLoader.maximumBytes, 10 * 1_048_576)
  }

  func testReadsOnlyFakeGitHubCLIAccountToken() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("shipios-pr-media-gh-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let executable = folder.appendingPathComponent("gh")
    let script = "#!/bin/sh\n[ \"$1 $2 $3 $4\" = 'auth token --hostname github.com' ] || exit 1\nprintf 'fake-token\\n'\n"
    XCTAssertTrue(FileManager.default.createFile(atPath: executable.path,
      contents: Data(script.utf8), attributes: [.posixPermissions: 0o700]))
    let token = await GitHubPRCommentMediaLoader.authenticationToken(executable: executable)
    XCTAssertEqual(token, "fake-token")
  }
}
