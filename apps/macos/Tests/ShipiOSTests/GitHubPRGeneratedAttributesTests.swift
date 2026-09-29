import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class GitHubPRGeneratedAttributesTests: XCTestCase {
  private let head = String(repeating: "a", count: 40)
  private let pr = GitHubPullRequest(number: 42, url: "https://github.com/sample/project/pull/42",
    title: "Feature", isDraft: false, headRefName: "feature", baseRefName: "main", isCrossRepository: false)
  private func patch(_ path: String, deleted: Bool = false) -> String {
    "diff --git a/\(path) b/\(path)\n" + (deleted ? "deleted file mode 100644\n" : "")
      + "--- a/\(path)\n+++ " + (deleted ? "/dev/null" : "b/\(path)")
      + (deleted ? "\n@@ -1 +0,0 @@\n-old\n" : "\n@@ -1 +1 @@\n-old\n+new\n")
  }
  private func code(_ paths: [String]) -> GitHubPRCodeSnapshot {
    .init(identity: .init(nodeID: "pr-node", head: head, base: String(repeating: "b", count: 40),
      headBranch: "feature", baseBranch: "main", changedFiles: paths.count), files: paths.map {
        .init(path: $0, oldPath: $0, patch: patch($0), kind: .modified, binary: false)
      })
  }
  private func fixture(_ extra: [String: Any] = [:]) async throws -> (GitHubPRCodeRequest, GitHubPRService) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-attributes-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    _ = try await GitReviewService.checked(["init", "-q", "-b", "unrelated-local-branch"], at: root)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/github_cli.py")
    let executable = root.appendingPathComponent(".git/gh-fixture")
    try FileManager.default.copyItem(at: source, to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let item = try JSONSerialization.jsonObject(with: JSONEncoder().encode(pr))
    var state: [String: Any] = ["head": head, "pullRequests": [item], "prDiff": patch("Sources/Main.swift")]
    extra.forEach { state[$0.key] = $0.value }
    try JSONSerialization.data(withJSONObject: state).write(to: root.appendingPathComponent(".git/github-fixture.json"))
    return (.init(taskID: "task-a", root: root, pullRequest: pr, head: head), .init(executable: executable))
  }
  private func logs(_ request: GitHubPRCodeRequest) throws -> [[String: Any]] {
    try String(contentsOf: request.root.appendingPathComponent(".git/github-requests.jsonl"))
      .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
  }
  private func update(_ request: GitHubPRCodeRequest, _ values: [String: Any]) throws {
    let path = request.root.appendingPathComponent(".git/github-fixture.json")
    var state = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
    values.forEach { state[$0.key] = $0.value }
    try JSONSerialization.data(withJSONObject: state).write(to: path)
  }
  private func waitForAttributes(_ request: GitHubPRCodeRequest) async throws {
    for _ in 0..<200 {
      if FileManager.default.fileExists(atPath: request.root.appendingPathComponent(".git/attributes-held").path) { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Attributes fixture did not reach its read gate")
  }

  func testPublicCodexMatcherGoldenCases() throws {
    struct Golden: Decodable {
      struct Case: Decodable { let pattern: String; let matches: [String] }
      let paths: [String]; let cases: [Case]
    }
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/pr_generated_attributes.json")
    let golden = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: path))
    for item in golden.cases {
      let value = try GitHubPRGeneratedAttributes(code: code(golden.paths), sources: [
        .init(basePath: "", contents: item.pattern + " linguist-generated")])
      XCTAssertEqual(value.generated, Set(item.matches), "Public Codex pattern: " + item.pattern)
    }
  }
  func testNestedRulesLastMatchAndExplicitUnsetAndUnspecified() throws {
    let paths = ["root.swift", "Sources/generated.swift", "Sources/manual.swift", "Sources/deep/keep.swift",
      "Sources/deep/reset.swift", "SourcesX/other.swift", ".hidden"]
    let value = try GitHubPRGeneratedAttributes(code: code(paths), sources: [
      .init(basePath: "", contents: "* linguist-generated\n*.swift linguist-generated=false\n**/*.swift linguist-generated=true"),
      .init(basePath: "Sources", contents: "*.swift -linguist-generated\ngenerated.swift linguist-generated"),
      .init(basePath: "Sources/deep", contents: "keep.swift linguist-generated\nreset.swift !linguist-generated")])
    XCTAssertEqual(value.generated, ["root.swift", "Sources/generated.swift", "Sources/deep/keep.swift", "SourcesX/other.swift", ".hidden"])
  }
  func testReferenceParserIgnoresMacrosQuotedSpacePatternsAndOtherValues() throws {
    let paths = ["one.swift", "two.swift", "three.swift", "my file.swift"]
    let value = try GitHubPRGeneratedAttributes(code: code(paths), sources: [.init(basePath: "", contents: """
      # ignored.swift linguist-generated
      [attr]generated linguist-generated
      one.swift generated
      two.swift linguist-generated=other
      "my file.swift" linguist-generated
      three.swift linguist-generated -linguist-generated linguist-generated=true
      """)])
    XCTAssertEqual(value.generated, ["three.swift"])
  }
  func testBOMAndJavaScriptWhitespaceAndOversizedPattern() throws {
    let value = try GitHubPRGeneratedAttributes(code: code(["main.swift", "other.swift"]), sources: [
      .init(basePath: "", contents: "\u{FEFF}main.swift\u{A0}linguist-generated\r\nother.swift\u{85}linguist-generated")])
    XCTAssertEqual(value.generated, ["main.swift"])
    XCTAssertThrowsError(try GitHubPRGeneratedAttributes(code: code(["main.swift"]), sources: [
      .init(basePath: "", contents: String(repeating: "a", count: 65_537) + " linguist-generated")]))
  }
  func testFixedRemoteHeadAncestorRulesAndNoLocalAttributes() async throws {
    let (request, service) = try await fixture(["attributeSources": [".gitattributes": "**/*.swift linguist-generated",
      "Sources/.gitattributes": "Main.swift !linguist-generated"]])
    try "** linguist-generated".write(to: request.root.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
    let snapshot = try await service.codeSnapshot(request)
    let value = try await service.generatedAttributes(request, code: snapshot)
    XCTAssertTrue(value.generated.isEmpty)
    let records = try logs(request)
    let read = try XCTUnwrap(records.first { ($0["input"] as? [String: Any])?["query"] as? String != nil
      && (($0["input"] as! [String: Any])["query"] as! String).contains("ShipiOSPRGeneratedAttributes") })
    let variables = (read["input"] as! [String: Any])["variables"] as! [String: String]
    XCTAssertEqual(Set(variables.values.filter { $0.contains(":") }), [head + ":.gitattributes", head + ":Sources/.gitattributes"])
    XCTAssertEqual(read["inputMode"] as? String, "0o600"); XCTAssertEqual(read["folderMode"] as? String, "0o700")
    XCTAssertTrue(records.allSatisfy { !(($0["args"] as? [String])?.contains("mutation") ?? false) })
  }
  func testAllAncestorsAreReadInBatchesOfFiftyAndUnicodeIsPreserved() async throws {
    let paths = (0..<55).map { "dir\($0)/sub/file.swift" } + ["中文/Main.swift"]
    let (request, service) = try await fixture(["codeChangedFiles": paths.count, "prDiff": paths.map { patch($0) }.joined(),
      "attributeSources": [".gitattributes": "**/*.swift linguist-generated", "中文/.gitattributes": "*.swift -linguist-generated"]])
    let snapshot = try await service.codeSnapshot(request), result = try await service.generatedAttributes(request, code: snapshot)
    XCTAssertEqual(result.generated.count, 55); XCTAssertFalse(result.generated.contains("中文/Main.swift"))
    let reads = try logs(request).compactMap { $0["input"] as? [String: Any] }.filter {
      ($0["query"] as? String)?.contains("ShipiOSPRGeneratedAttributes") == true }
    XCTAssertEqual(reads.count, 3)
    XCTAssertEqual(reads.map { ($0["variables"] as! [String: Any]).count - 2 }, [50, 50, 12])
  }
  func testMissingBinaryAndTreeAttributesDoNotInventGeneratedRules() async throws {
    for override: [String: Any] in [[:], ["f0": ["__typename": "Tree"]],
      ["f0": ["__typename": "Blob", "text": NSNull(), "isTruncated": false, "isBinary": true, "byteSize": 3]]] {
      let (request, service) = try await fixture(["attributesOverride": override])
      let snapshot = try await service.codeSnapshot(request), result = try await service.generatedAttributes(request, code: snapshot)
      XCTAssertTrue(result.generated.isEmpty)
    }
  }
  func testMalformedTruncatedAndIncompleteAttributesFailWithoutDiscardingCode() async throws {
    for extra: [String: Any] in [["attributesFailure": true], ["attributesGraphQLError": true],
      ["attributesRepository": "other/project"], ["attributesOmitAlias": true],
      ["attributesOverride": ["f0": [:]]],
      ["attributesOverride": ["f0": ["__typename": "Blob", "isTruncated": true, "text": "*"]]],
      ["attributesOverride": ["f0": ["__typename": "Blob", "isTruncated": false, "text": "*", "byteSize": 30]]]] {
      let (request, service) = try await fixture(extra), state = GitHubPRCodeState(service: service)
      await state.load(request, valid: { true }); await state.loadAttributes(valid: { true })
      XCTAssertNotNil(state.snapshot); XCTAssertNil(state.error); XCTAssertNotNil(state.attributesError)
      XCTAssertNil(state.attributes); XCTAssertTrue(state.generatedPaths.isEmpty); XCTAssertFalse(state.attributesLoading)
      XCTAssertFalse(state.attributesStale)
    }
  }
  func testHeadAndBaseDriftDoNotInstallOldRulesAndChooseDiffRefresh() async throws {
    for extra in [["headAfterAttributes": String(repeating: "c", count: 40)], ["baseAfterAttributes": String(repeating: "d", count: 40)]] {
      let (request, service) = try await fixture(extra), state = GitHubPRCodeState(service: service)
      await state.load(request, valid: { true }); await state.loadAttributes(valid: { true })
      XCTAssertNil(state.attributes); XCTAssertNotNil(state.attributesError); XCTAssertTrue(state.attributesStale)
      XCTAssertNotNil(state.snapshot)
    }
  }
  func testFailureRetryCachesSuccessAndKeepsManualExpansionAndCommentJump() async throws {
    let (request, service) = try await fixture(["attributesFailure": true,
      "attributeSources": [".gitattributes": "**/*.swift linguist-generated"]])
    let state = GitHubPRCodeState(service: service); await state.load(request, valid: { true })
    await state.loadAttributes(valid: { true }); XCTAssertNotNil(state.attributesError)
    state.open(.init(path: "Sources/Main.swift", line: 1, side: .right, startLine: nil, startSide: nil))
    try update(request, ["attributesFailure": false])
    await state.loadAttributes(force: true, valid: { true })
    XCTAssertNil(state.attributesError); XCTAssertEqual(state.generatedPaths, ["Sources/Main.swift"])
    XCTAssertFalse(state.allCollapsed); XCTAssertEqual(state.position?.line, 1)
    let before = try logs(request).count
    await state.loadAttributes(valid: { true }); XCTAssertEqual(try logs(request).count, before)
    state.toggle("Sources/Main.swift"); XCTAssertTrue(state.allCollapsed)
    await state.refresh(request, valid: { true }); await state.loadAttributes(valid: { true })
    XCTAssertTrue(state.allCollapsed)
  }
  func testGeneratedAndDeletedDefaultsAndLateManualOverride() async throws {
    let paths = ["Generated.swift", "Sources/Main.swift", "deleted.swift"]
    let (request, service) = try await fixture(["attributesGate": true, "codeChangedFiles": 3,
      "prDiff": patch(paths[0]) + patch(paths[1]) + patch(paths[2], deleted: true),
      "attributeSources": [".gitattributes": "Generated.swift linguist-generated"]])
    let state = GitHubPRCodeState(service: service); await state.load(request, valid: { true })
    XCTAssertEqual(state.collapsed, ["deleted.swift"])
    let read = Task { await state.loadAttributes(valid: { true }) }; try await waitForAttributes(request)
    XCTAssertTrue(state.attributesLoading); XCTAssertFalse(state.loading); XCTAssertEqual(state.files.count, 3)
    state.toggle("Generated.swift"); state.toggle("Generated.swift")
    state.toggle("Sources/Main.swift")
    try Data().write(to: request.root.appendingPathComponent(".git/attributes-release")); await read.value
    XCTAssertEqual(state.generatedPaths, ["Generated.swift"])
    XCTAssertEqual(state.collapsed, ["Sources/Main.swift", "deleted.swift"])
    state.toggleAll(); XCTAssertTrue(state.allCollapsed)
    state.toggleAll(); XCTAssertTrue(state.collapsed.isEmpty)
    await state.loadAttributes(force: true, valid: { true }); XCTAssertTrue(state.collapsed.isEmpty)
  }
  func testLateReadCannotCrossInvalidatedOrChangedTask() async throws {
    let (request, service) = try await fixture(["attributesGate": true,
      "attributeSources": [".gitattributes": "** linguist-generated"]])
    let state = GitHubPRCodeState(service: service); await state.load(request, valid: { true })
    let read = Task { await state.loadAttributes(valid: { true }) }; try await waitForAttributes(request)
    state.invalidate()
    let other = GitHubPRCodeRequest(taskID: "task-b", root: request.root, pullRequest: request.pullRequest, head: request.head)
    await state.load(other, valid: { true })
    try Data().write(to: request.root.appendingPathComponent(".git/attributes-release")); await read.value
    XCTAssertNil(state.attributes); XCTAssertFalse(state.attributesLoading); XCTAssertTrue(state.collapsed.isEmpty)
    await state.loadAttributes(valid: { true }); XCTAssertTrue(state.allCollapsed)
  }
  func testCancelledAndInvalidReadsPreserveCodeAndPermitRetry() async throws {
    let (request, service) = try await fixture(["attributesGate": true,
      "attributeSources": [".gitattributes": "** linguist-generated"]])
    let state = GitHubPRCodeState(service: service); await state.load(request, valid: { true })
    let read = Task { await state.loadAttributes(valid: { true }) }; try await waitForAttributes(request)
    read.cancel(); await read.value
    XCTAssertNotNil(state.snapshot); XCTAssertNil(state.attributes); XCTAssertNil(state.attributesError); XCTAssertFalse(state.attributesLoading)
    try Data().write(to: request.root.appendingPathComponent(".git/attributes-release"))
    await state.loadAttributes(valid: { false }); XCTAssertNil(state.attributes)
    await state.loadAttributes(valid: { true }); XCTAssertTrue(state.allCollapsed)
  }
  func testHiddenNativeGeneratedCollapseAndExplicitExpansion() async throws {
    let (request, service) = try await fixture(["attributeSources": [".gitattributes": "** linguist-generated"]])
    let state = GitHubPRCodeState(service: service); await state.load(request, valid: { true })
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
      styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: TaskPullRequestCodeFileView(file: state.files[0], state: state,
      threads: [], comment: { _ in EmptyView() }).frame(width: 720))
    window.contentView = host
    try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
    let expanded = host.fittingSize.height
    await state.loadAttributes(valid: { true })
    try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
    XCTAssertLessThan(host.fittingSize.height, expanded)
    state.open(.init(path: "Sources/Main.swift", line: 1, side: .right, startLine: nil, startSide: nil))
    try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
    XCTAssertEqual(host.fittingSize.height, expanded, accuracy: 1); XCTAssertFalse(window.isVisible)
  }
  func testEmptyPRDoesNotReadAttributesAndOtherWindowsKeepIndependentDefaults() async throws {
    let (empty, emptyService) = try await fixture(["prDiff": "", "codeChangedFiles": 0])
    let state = GitHubPRCodeState(service: emptyService)
    await state.load(empty, valid: { true }); let before = try logs(empty).count
    await state.loadAttributes(valid: { true }); XCTAssertEqual(try logs(empty).count, before)
    XCTAssertNotNil(state.attributes); XCTAssertTrue(state.generatedPaths.isEmpty)
    let (request, service) = try await fixture(["attributeSources": [".gitattributes": "** linguist-generated"]])
    let first = GitHubPRCodeState(service: service), second = GitHubPRCodeState(service: service)
    await first.load(request, valid: { true }); await first.loadAttributes(valid: { true })
    await second.load(request, valid: { true }); await second.loadAttributes(valid: { true })
    first.toggleAll(); XCTAssertFalse(first.groupExpanded); XCTAssertTrue(first.allCollapsed)
    first.toggleAll(); XCTAssertTrue(first.collapsed.isEmpty); XCTAssertTrue(second.allCollapsed)
  }
  func testGroupToggleKeepsItsOwnStateDespiteDefaultGeneratedCollapseAndManualToggle() async throws {
    let (request, service) = try await fixture(["attributeSources": [".gitattributes": "** linguist-generated"]])
    let state = GitHubPRCodeState(service: service)
    await state.load(request, valid: { true }); await state.loadAttributes(valid: { true })
    XCTAssertTrue(state.allCollapsed); XCTAssertTrue(state.groupExpanded)
    state.toggleAll(); XCTAssertFalse(state.groupExpanded); XCTAssertTrue(state.allCollapsed)
    state.toggle("Sources/Main.swift"); XCTAssertFalse(state.groupExpanded); XCTAssertFalse(state.allCollapsed)
    state.toggleAll(); XCTAssertTrue(state.groupExpanded); XCTAssertFalse(state.allCollapsed)
    state.toggle("Sources/Main.swift"); XCTAssertTrue(state.groupExpanded); XCTAssertTrue(state.allCollapsed)
    await state.loadAttributes(force: true, valid: { true }); XCTAssertTrue(state.allCollapsed)
  }
}
