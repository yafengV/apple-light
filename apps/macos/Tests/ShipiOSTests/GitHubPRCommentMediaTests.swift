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
    let blocks = MessageDocument.parse(source, githubMedia: true)
    XCTAssertEqual(blocks.count, 5)
    guard case .paragraph = blocks[0].kind, case .media(let image) = blocks[1].kind,
      case .paragraph = blocks[2].kind, case .media(let video) = blocks[3].kind,
      case .paragraph = blocks[4].kind else {
      return XCTFail("Expected text, image, text, video, text")
    }
    XCTAssertEqual(String(blocks[0].text.characters).trimmingCharacters(in: .whitespaces), "Before bold")
    XCTAssertTrue(blocks[0].text.runs.contains(where: {
      $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
    }))
    XCTAssertEqual(image.kind, .image)
    XCTAssertEqual(image.alt, "chart")
    XCTAssertEqual(String(blocks[2].text.characters).trimmingCharacters(in: .whitespaces), "after.")
    XCTAssertEqual(video.kind, .video)
    XCTAssertEqual(String(blocks[4].text.characters), "Tail")
  }

  func testCodeAndUntrustedImagesStayInMarkdown() {
    let source = "```md\n![fake](https://github.com/user-attachments/assets/id)\n```\n\n" +
      "![external](https://example.com/picture.png)"
    let ordinary = MessageDocument.parse(source)
    XCTAssertEqual(MessageDocument.parse(source, githubMedia: true), ordinary)
  }

  func testStandaloneHTMLMediaAndExtraHTML() {
    let image = "<img alt=\"chart\" src=\"https://user-images.githubusercontent.com/a.png\">"
    guard case .media(let item) = MessageDocument.parse(image, githubMedia: true).first?.kind else {
      return XCTFail("Expected HTML image")
    }
    XCTAssertEqual(item.kind, .image)
    XCTAssertEqual(item.alt, "chart")
    let escaped = "<img alt=\"A &amp; B\" src=\"https://private-user-images.githubusercontent.com/a.png?x=1&amp;y=2\">"
    guard case .media(let signed) = MessageDocument.parse(escaped, githubMedia: true).first?.kind else {
      return XCTFail("Expected signed HTML image")
    }
    XCTAssertEqual(signed.alt, "A & B")
    XCTAssertEqual(signed.url.query, "x=1&y=2")
    let unsafe = image + "<script>alert(1)</script>"
    XCTAssertFalse(MessageDocument.parse(unsafe, githubMedia: true).contains(where: {
      if case .media = $0.kind { true } else { false }
    }))
  }

  func testMediaInsideListQuoteAndTableKeepsItsContainer() {
    let image = "![chart](https://user-images.githubusercontent.com/a.png)"
    let source = "- before " + image + " after\n\n> " + image +
      "\n\n| file | image |\n| --- | --- |\n| A | " + image + " |"
    let blocks = MessageDocument.parse(source, githubMedia: true)
    XCTAssertEqual(blocks.count, 3)
    guard case .list = blocks[0].kind, case .quote = blocks[1].kind,
      case .table = blocks[2].kind else { return XCTFail("Expected list, quote, table") }
    XCTAssertEqual(blocks[0].children[0].children.count, 3)
    guard case .media(let listMedia) = blocks[0].children[0].children[1].kind,
      case .media(let quoteMedia) = blocks[1].children[0].kind,
      case .media(let cellMedia) = blocks[2].mediaRows[1][1][0].kind else {
      return XCTFail("Expected media in all three nested containers")
    }
    XCTAssertEqual([listMedia.alt, quoteMedia.alt, cellMedia.alt], ["chart", "chart", "chart"])
    XCTAssertTrue(MessageDocument.parse(source).allSatisfy { block in
      if case .media = block.kind { return false }
      return true
    })
  }

  func testHeadingImageKeepsHeadingTextStyle() {
    let source = "# Results ![chart](https://user-images.githubusercontent.com/a.png)"
    let blocks = MessageDocument.parse(source, githubMedia: true)
    XCTAssertEqual(blocks.count, 2)
    guard case .heading(1) = blocks[0].kind, case .media(let image) = blocks[1].kind else {
      return XCTFail("Expected heading and image")
    }
    XCTAssertEqual(String(blocks[0].text.characters).trimmingCharacters(in: .whitespaces), "Results")
    XCTAssertEqual(image.alt, "chart")
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
