import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class GitHubPRCodeTests: XCTestCase {
  private let head = String(repeating: "a", count: 40)
  private let pr = GitHubPullRequest(number: 42, url: "https://github.com/sample/project/pull/42",
    title: "Feature", isDraft: false, headRefName: "feature", baseRefName: "main", isCrossRepository: false)
  private let patch = "diff --git a/Sources/Main.swift b/Sources/Main.swift\n--- a/Sources/Main.swift\n+++ b/Sources/Main.swift\n@@ -8,2 +8,2 @@\n old\n-before\n+after\n"
  private func fixture(_ extra: [String: Any] = [:]) async throws -> (GitHubPRCodeRequest, GitHubPRService) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-code-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    _ = try await GitReviewService.checked(["init", "-q", "-b", "unrelated-local-branch"], at: root)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/github_cli.py")
    let executable = root.appendingPathComponent(".git/gh-fixture")
    try FileManager.default.copyItem(at: source, to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let item = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pr))
    var state: [String: Any] = ["head": head, "pullRequests": [item], "prDiff": patch]
    extra.forEach { state[$0.key] = $0.value }
    try JSONSerialization.data(withJSONObject: state).write(to: root.appendingPathComponent(".git/github-fixture.json"))
    return (.init(taskID: "task-a", root: root, pullRequest: pr, head: head), .init(executable: executable))
  }
  private func position(_ path: String = "Sources/Main.swift", line: Int = 9,
    side: GitHubPRCommentPosition.Side = .right) -> GitHubPRCommentPosition {
    .init(path: path, line: line, side: side, startLine: nil, startSide: nil)
  }
  private func failure(_ work: () async throws -> Void) async -> String {
    do { try await work(); XCTFail("Expected failure"); return "" } catch { return error.localizedDescription }
  }
  private func waitForGate(_ root: URL) async throws {
    for _ in 0..<200 {
      if FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/code-diff-held").path) { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("CLI did not reach the confirmed read gate")
  }

  func testRichMarkdownPreviewReadsExactHeadObjectAndRejectsIncompleteData() async throws {
    let markdownDiff = "diff --git a/Docs/README.md b/Docs/README.md\n--- a/Docs/README.md\n+++ b/Docs/README.md\n@@ -1 +1 @@\n-old\n+new\n"
    let (request, service) = try await fixture(["prDiff": markdownDiff, "previewText": "# 标题\n正文\n"])
    let code = try await service.codeSnapshot(request)
    XCTAssertTrue(GitHubPRRichPreview.supportsMarkdown(code.files[0]))
    let preview = try await service.richPreviewText(request, code: code, file: code.files[0])
    XCTAssertEqual(preview, "# 标题\n正文\n")
    let records = try String(contentsOf: request.root.appendingPathComponent(".git/github-requests.jsonl"))
    XCTAssertTrue(records.contains(head + ":Docs/README.md"))

    let unavailable = GitHubPRCodeFile(path: "Docs/missing.md", oldPath: nil, patch: "", kind: .added, binary: false)
    let error = await failure { _ = try await service.richPreviewText(request, code: code, file: unavailable) }
    XCTAssertTrue(error.contains("不支持"))
    XCTAssertFalse(GitHubPRRichPreview.supportsMarkdown(.init(path: "Docs/README.md", oldPath: nil,
      patch: "", kind: .deleted, binary: false)))
    XCTAssertFalse(GitHubPRRichPreview.supportsMarkdown(.init(path: "Docs/README.md", oldPath: nil,
      patch: "", kind: .modified, binary: true)))

    for extra: [String: Any] in [["previewOverride": ["isTruncated": true]],
      ["previewOverride": ["byteSize": 1]], ["previewRepository": "other/project"],
      ["headAfterPreview": String(repeating: "c", count: 40)]] {
      let (nextRequest, nextService) = try await fixture(["prDiff": markdownDiff, "previewText": "# Preview\n"].merging(extra) { _, value in value })
      let nextCode = try await nextService.codeSnapshot(nextRequest)
      let message = await failure {
        _ = try await nextService.richPreviewText(nextRequest, code: nextCode, file: nextCode.files[0])
      }
      XCTAssertFalse(message.isEmpty)
    }
  }

  func testRichPreviewCannotInstallAfterTaskScopeChanges() async throws {
    let markdownDiff = "diff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-old\n+new\n"
    let (request, service) = try await fixture(["prDiff": markdownDiff, "previewGate": true])
    let state = GitHubPRCodeState(service: service)
    await state.load(request, valid: { true })
    let file = try XCTUnwrap(state.files.first), identity = try XCTUnwrap(state.snapshot?.identity)
    let read = Task { await failure { _ = try await state.richPreviewText(file, identity: identity) } }
    for _ in 0..<200 {
      if FileManager.default.fileExists(atPath: request.root.appendingPathComponent(".git/preview-held").path) { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: request.root.appendingPathComponent(".git/preview-held").path))
    state.invalidate()
    try Data().write(to: request.root.appendingPathComponent(".git/preview-release"))
    let message = await read.value
    XCTAssertTrue(message.contains("版本已变化"))
    XCTAssertNil(state.snapshot)
  }

  func testHiddenMarkdownPreviewChangesRenderedCodeSurface() async throws {
    let markdownDiff = "diff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-old\n+new\n"
    let (request, service) = try await fixture(["prDiff": markdownDiff,
      "previewText": "# Rendered heading\n\nA full paragraph from the PR head.\n"])
    let state = GitHubPRCodeState(service: service)
    await state.load(request, valid: { true })
    let file = try XCTUnwrap(state.files.first)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
      styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: TaskPullRequestCodeFileView(file: file, state: state,
      threads: [], richPreviewEnabled: true, comment: { _ in EmptyView() }).frame(width: 720, height: 400))
    window.contentView = host
    let logURL = request.root.appendingPathComponent(".git/github-requests.jsonl")
    for _ in 0..<50 {
      if (try? String(contentsOf: logURL))?.contains("ShipiOSPRRichPreview") == true { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    try await Task.sleep(for: .milliseconds(300))
    host.layoutSubtreeIfNeeded()
    let rich = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rich)
    host.rootView = TaskPullRequestCodeFileView(file: file, state: state,
      threads: [], richPreviewEnabled: false, comment: { _ in EmptyView() }).frame(width: 720, height: 400)
    try await Task.sleep(for: .milliseconds(200))
    host.layoutSubtreeIfNeeded()
    let diff = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: diff)
    XCTAssertNotEqual(rich.representation(using: .png, properties: [:]),
      diff.representation(using: .png, properties: [:]))
    XCTAssertFalse(window.isVisible)
  }

  func testReadsRemoteDiffWithoutDependingOnLocalBranchAndChecksBothRevisions() async throws {
    let (request, service) = try await fixture()
    let value = try await service.codeSnapshot(request)
    XCTAssertEqual(value.files.map(\.path), ["Sources/Main.swift"])
    XCTAssertEqual(value.identity.head, head); XCTAssertEqual(value.identity.base, String(repeating: "b", count: 40))
    XCTAssertEqual(value.files[0].diff.additions, 1); XCTAssertEqual(value.files[0].diff.deletions, 1)
    let records = try String(contentsOf: request.root.appendingPathComponent(".git/github-requests.jsonl"))
      .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    XCTAssertEqual(records.count, 3)
    XCTAssertEqual(records[1]["args"] as? [String], ["pr", "diff", "42", "--repo", "sample/project", "--color", "never"])
    XCTAssertTrue(records.allSatisfy { !(($0["args"] as? [String])?.contains("mutation") ?? false) })
  }
  func testHeadDriftAndBaseOnlyDriftRejectCapturedDiff() async throws {
    for extra in [["headAfterDiff": String(repeating: "c", count: 40)], ["baseAfterDiff": String(repeating: "d", count: 40)]] {
      let (request, service) = try await fixture(extra)
      let error = await failure { _ = try await service.codeSnapshot(request) }
      XCTAssertTrue(error.contains("读取差异时发生变化"))
    }
  }
  func testWrongPRRepositoryInvalidRevisionAndStaleHeadRejectBeforeDiff() async throws {
    for extra: [String: Any] in [["codeMismatch": true], ["metadataRepository": "other/project"],
      ["codeBase": "invalid"], ["detailHead": String(repeating: "c", count: 40)]] {
      let (request, service) = try await fixture(extra)
      _ = await failure { _ = try await service.codeSnapshot(request) }
      let log = try String(contentsOf: request.root.appendingPathComponent(".git/github-requests.jsonl"))
      XCTAssertFalse(log.contains("\"diff\""))
    }
  }
  func testMissingFilesMalformedAndDuplicateDiffDoNotBecomeSuccess() async throws {
    for extra: [String: Any] in [["codeChangedFiles": 2], ["prDiff": "unexpected"], ["prDiff": patch + patch],
      ["diffFailure": true], ["codeReadFailure": true]] {
      let (request, service) = try await fixture(extra)
      let state = GitHubPRCodeState(service: service)
      await state.load(request, valid: { true })
      XCTAssertNil(state.snapshot); XCTAssertNotNil(state.error); XCTAssertFalse(state.loading)
    }
  }
  func testEmptyRemotePRHasExplicitEmptySnapshot() async throws {
    let (request, service) = try await fixture(["codeChangedFiles": 0, "prDiff": ""])
    let state = GitHubPRCodeState(service: service); await state.load(request, valid: { true })
    XCTAssertEqual(state.snapshot?.files.count, 0); XCTAssertNil(state.error)
  }
  func testParseAddedDeletedRenamedCopiedAndModeOnlyFiles() throws {
    let source = """
      diff --git a/new.swift b/new.swift
      new file mode 100644
      --- /dev/null
      +++ b/new.swift
      @@ -0,0 +1 @@
      +new
      diff --git a/old.swift b/old.swift
      deleted file mode 100644
      --- a/old.swift
      +++ /dev/null
      @@ -1 +0,0 @@
      -old
      diff --git a/before.swift b/after.swift
      similarity index 100%
      rename from before.swift
      rename to after.swift
      diff --git a/source.swift b/copy.swift
      similarity index 100%
      copy from source.swift
      copy to copy.swift
      diff --git a/script.sh b/script.sh
      old mode 100644
      new mode 100755
      """
    let files = try GitHubPRCodeFile.parse(source)
    XCTAssertEqual(files.map(\.path), ["new.swift", "old.swift", "after.swift", "copy.swift", "script.sh"])
    XCTAssertEqual(files.map(\.kind), [.added, .deleted, .renamed, .copied, .modified])
    XCTAssertEqual(files.map(\.defaultCollapsed), [false, true, false, false, false])
    XCTAssertNil(files[0].oldPath); XCTAssertEqual(files[2].oldPath, "before.swift")
  }
  func testUnicodeQuotedPathsAndBinaryNamesWithSpacesArePreserved() throws {
    let source = #"""
      diff --git "a/\344\270\255\346\226\207.swift" "b/\344\270\255\346\226\207.swift"
      --- "a/\344\270\255\346\226\207.swift"
      +++ "b/\344\270\255\346\226\207.swift"
      @@ -1 +1 @@
      -old
      +new
      diff --git a/assets/my b/picture.png b/assets/my b/picture.png
      Binary files a/assets/my b/picture.png and b/assets/my b/picture.png differ
      """#
    let files = try GitHubPRCodeFile.parse(source)
    XCTAssertEqual(files.map(\.path), ["中文.swift", "assets/my b/picture.png"])
    XCTAssertTrue(files[1].binary); XCTAssertEqual(files[0].diff.lines.last?.newLine, 1)
  }
  func testPathTraversalAndAbsoluteMarkersAreRejected() {
    for path in ["../outside", "/absolute"] {
      XCTAssertThrowsError(try GitHubPRCodeFile.parse("diff --git a/file b/file\n--- a/file\n+++ " + path))
    }
  }
  func testSplitRowsPairUnequalRunsAndPreserveBothLineAnchors() {
    let diff = ReviewDiff("@@ -1,4 +1,3 @@\n context\n-old1\n-old2\n-old3\n+new1\n+new2")
    let rows = GitHubPRSplitLine.rows(diff.lines)
    XCTAssertEqual(rows.count, 5)
    XCTAssertEqual(rows[2].left?.oldLine, 2); XCTAssertEqual(rows[2].right?.newLine, 2)
    XCTAssertEqual(rows[4].left?.oldLine, 4); XCTAssertNil(rows[4].right)
  }
  func testPendingCommentJumpClearsSearchAndExpandsDeletedFileAfterLoad() async throws {
    let deleted = "diff --git a/deleted.swift b/deleted.swift\ndeleted file mode 100644\n--- a/deleted.swift\n+++ /dev/null\n@@ -9 +0,0 @@\n-old"
    let (request, service) = try await fixture(["prDiff": deleted])
    let state = GitHubPRCodeState(service: service); state.query = "other"
    state.open(position("deleted.swift", side: .left))
    XCTAssertEqual(state.page, .code); XCTAssertEqual(state.query, "")
    await state.load(request, valid: { true })
    XCTAssertEqual(state.selectedPath, "deleted.swift"); XCTAssertFalse(state.collapsed.contains("deleted.swift"))
    XCTAssertNotNil(state.rowTarget(in: try XCTUnwrap(state.files.first)))
  }
  func testRenameLeftJumpFindsNewPathAndHighlightsOriginalSideOnly() async throws {
    let renamed = "diff --git a/old.swift b/new.swift\nrename from old.swift\nrename to new.swift\n--- a/old.swift\n+++ b/new.swift\n@@ -9 +9 @@\n-before\n+after"
    let (request, service) = try await fixture(["prDiff": renamed])
    let state = GitHubPRCodeState(service: service); await state.load(request, valid: { true })
    state.open(position("old.swift", side: .left))
    XCTAssertEqual(state.selectedPath, "new.swift"); XCTAssertEqual(state.position?.side, .left)
    XCTAssertNotNil(state.rowTarget(in: state.files[0]))
    state.open(position("old.swift", side: .right))
    XCTAssertEqual(state.selectedPath, "new.swift") // Invalid new-side old filename cannot select another file.
    XCTAssertNil(state.position) // Never retain the preceding comment's highlight.
    state.open(position("new.swift", line: 999)); XCTAssertNil(state.rowTarget(in: state.files[0]))
  }
  func testFileSearchDoesNotFilterRenderedDiffAndCollapseAndWindowStatesAreIndependent() async throws {
    let (request, service) = try await fixture()
    let state = GitHubPRCodeState(service: service), other = GitHubPRCodeState(service: service)
    await state.load(request, valid: { true }); await other.load(request, valid: { true })
    state.query = "  main.SWIFT "; XCTAssertEqual(state.filteredFiles.count, 1)
    state.query = "absent"; XCTAssertTrue(state.filteredFiles.isEmpty); XCTAssertEqual(state.files.count, 1)
    state.toggleAll(); XCTAssertTrue(state.allCollapsed); XCTAssertFalse(other.allCollapsed)
    state.open(position()); XCTAssertFalse(state.allCollapsed); XCTAssertEqual(state.query, "")
    let old = state.navigation; state.open(position()); XCTAssertNotEqual(state.navigation, old)
    state.select("Sources/Main.swift"); XCTAssertNil(state.position)
  }
  func testTreeGroupsFoldersBeforeFilesAndKeepsIdenticalBasenamesDistinct() throws {
    let files = try GitHubPRCodeFile.parse(patch + patch.replacingOccurrences(of: "Sources/", with: "Tests/")
      + patch.replacingOccurrences(of: "Sources/Main.swift", with: "README.md"))
    let nodes = GitHubPRCodeTreeNode.tree(files)
    XCTAssertEqual(nodes.map(\.name), ["Sources", "Tests", "README.md"])
    XCTAssertEqual(nodes[0].children.first?.file?.path, "Sources/Main.swift")
    XCTAssertEqual(nodes[1].children.first?.file?.path, "Tests/Main.swift")
  }
  func testInvalidatedTaskCannotInstallLateDiffAndRetryPreservesPendingJump() async throws {
    let (request, service) = try await fixture(["codeDiffGate": true])
    let state = GitHubPRCodeState(service: service)
    let read = Task { await state.load(request, valid: { true }) }
    try await waitForGate(request.root)
    state.open(position()); state.invalidate()
    try Data().write(to: request.root.appendingPathComponent(".git/code-diff-release"))
    await read.value; XCTAssertNil(state.snapshot); XCTAssertFalse(state.loading)
    await state.load(request, valid: { true })
    XCTAssertEqual(state.selectedPath, "Sources/Main.swift"); XCTAssertEqual(state.position?.line, 9)
  }
  func testCancelledLoadCannotInstallDataAndRetryWorks() async throws {
    let (request, service) = try await fixture(["codeDiffGate": true])
    let state = GitHubPRCodeState(service: service)
    let read = Task { await state.load(request, valid: { true }) }
    try await waitForGate(request.root); read.cancel(); await read.value
    XCTAssertNil(state.snapshot); XCTAssertNil(state.error); XCTAssertFalse(state.loading)
    try Data().write(to: request.root.appendingPathComponent(".git/code-diff-release"))
    await state.load(request, valid: { true }); XCTAssertNotNil(state.snapshot)
  }
  func testInvalidScopeDiscardsSnapshotAndInvalidPositionDoesNotChangePage() async throws {
    let (request, service) = try await fixture()
    let state = GitHubPRCodeState(service: service); state.open(position(line: 0))
    XCTAssertEqual(state.page, .summary)
    await state.load(request, valid: { true }); XCTAssertNotNil(state.snapshot)
    await state.load(request, valid: { false }); XCTAssertNil(state.snapshot)
  }
  func testMetadataRefreshDoesNotReloadDiffButBranchAndTaskChangesDo() async throws {
    let (request, service) = try await fixture()
    let state = GitHubPRCodeState(service: service); await state.load(request, valid: { true })
    let changed = GitHubPullRequest(number: pr.number, url: pr.url, title: "Updated title", isDraft: false,
      headRefName: pr.headRefName, baseRefName: pr.baseRefName, isCrossRepository: false, checkedAt: Date())
    let same = GitHubPRCodeRequest(taskID: request.taskID, root: request.root, pullRequest: changed, head: head.uppercased())
    XCTAssertEqual(same, request)
    let logURL = request.root.appendingPathComponent(".git/github-requests.jsonl")
    let original = try Data(contentsOf: logURL)
    await state.load(same, valid: { true }); XCTAssertEqual(try Data(contentsOf: logURL), original)
    state.invalidate(); state.open(position())
    state.query = "old filter"; state.showsFiles = true
    let other = GitHubPRCodeRequest(taskID: "task-b", root: request.root, pullRequest: changed, head: head)
    await state.load(other, valid: { true }); XCTAssertNil(state.position)
    XCTAssertEqual(state.query, ""); XCTAssertFalse(state.showsFiles)
    let retargeted = GitHubPullRequest(number: pr.number, url: pr.url, title: pr.title, isDraft: false,
      headRefName: pr.headRefName, baseRefName: "release", isCrossRepository: false)
    XCTAssertNotEqual(request, GitHubPRCodeRequest(taskID: request.taskID, root: request.root, pullRequest: retargeted, head: head))
  }
  func testHiddenNativeCodeRenderingRespondsToCollapseSplitAndWrap() async throws {
    let (request, service) = try await fixture()
    let state = GitHubPRCodeState(service: service); await state.load(request, valid: { true })
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
      styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: TaskPullRequestCodeFileView(file: state.files[0], state: state,
      threads: [], comment: { _ in EmptyView() }).frame(width: 720))
    window.contentView = host
    try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
    let height = host.fittingSize.height
    state.toggleAll(); try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
    XCTAssertLessThan(host.fittingSize.height, height)
    state.toggleAll(); state.split = true; state.wrap = true
    try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(host.fittingSize.height, 30)
    XCTAssertFalse(window.isVisible)
  }
}
