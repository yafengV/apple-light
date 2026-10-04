import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

@MainActor final class GitHubPROverviewTests: XCTestCase {
  private let head = String(repeating: "a", count: 40)
  private let request = GitHubPullRequest(number: 42, url: "https://github.com/sample/project/pull/42",
    title: "Feature", isDraft: false, headRefName: "feature/very-long-branch-name", baseRefName: "main", isCrossRepository: false)
  private func fixture(_ changes: [String: Any] = [:]) async throws -> (URL, GitHubPRService) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-overview-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    _ = try await GitReviewService.checked(["init", "-q", "-b", "feature"], at: root)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/github_cli.py")
    let executable = root.appendingPathComponent(".git/gh-fixture")
    try FileManager.default.copyItem(at: source, to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    var fields: [String: Any] = ["head": head, "viewer": "owner", "author": "owner",
      "pullRequests": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))]]
    changes.forEach { fields[$0.key] = $0.value }
    try JSONSerialization.data(withJSONObject: fields).write(to: root.appendingPathComponent(".git/github-fixture.json"))
    return (root, .init(executable: executable))
  }

  func testDetailsReadRemoteStatisticsFromTheExplicitPRWithoutCloningOrDiffEstimates() async throws {
    let (root, service) = try await fixture(["additions": 1200345, "deletions": 0])
    let result = try await service.details(for: request, at: root)
    XCTAssertEqual(result.additions, 1200345); XCTAssertEqual(result.deletions, 0)
    let logs = try String(contentsOf: root.appendingPathComponent(".git/github-requests.jsonl")).split(separator: "\n")
    XCTAssertEqual(logs.count, 1)
    let call = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(logs[0].utf8)) as? [String: Any])
    let args = try XCTUnwrap(call["args"] as? [String])
    XCTAssertEqual(Array(args.prefix(5)), ["pr", "view", "42", "--repo", "sample/project"])
    XCTAssertTrue(args.last?.contains("additions,deletions") == true)
    XCTAssertFalse(args.contains("diff"))
  }

  func testMissingStatisticsRemainUnknownAndMalformedCountsCannotDisplayFabricatedNumbers() async throws {
    let (root, service) = try await fixture(["additions": NSNull(), "deletions": NSNull()])
    let value = try await service.details(for: request, at: root)
    XCTAssertNil(value.additions); XCTAssertNil(value.deletions)
    for fields: [String: Any] in [["additions": -1], ["deletions": -1], ["additions": "12"], ["deletions": 2.5], ["detailMismatch": true]] {
      let (root, service) = try await fixture(fields)
      do { _ = try await service.details(for: request, at: root); XCTFail("Accepted malformed or wrong PR: \(fields)") } catch { }
    }
  }

  private func settle(_ host: NSView) async throws {
    try await Task.sleep(for: .milliseconds(250)); host.layoutSubtreeIfNeeded()
  }
  private func host<V: View>(_ content: V, width: CGFloat) -> (NSWindow, NSHostingView<V>) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: 300),
      styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
    let host = NSHostingView(rootView: content); window.contentView = host
    return (window, host)
  }

  func testHiddenNativeOverviewRendersAtNarrowAndWideWidths() async throws {
    let (root, service) = try await fixture(["autoMerge": true])
    let metadata = try await service.mergeSnapshot(for: request, at: root)
    let checks = GitHubPRChecksState(service: service), discussion = GitHubPRDiscussionState(service: service)
    let reviewers = GitHubPRReviewerState(service: service)
    await checks.load(.init(taskID: "t", root: root, pullRequest: request, headRevision: head), valid: { true })
    await discussion.load(request, at: root, valid: { true }); await reviewers.load(request, at: root, valid: { true })
    for width: CGFloat in [284, 383, 384, 700] {
      let view = TaskPullRequestOverviewView(snapshot: metadata, request: request, loading: false,
        error: nil, checks: checks, discussion: discussion, reviewers: reviewers, writable: true,
        searchReviewers: { _ in }, retryReviewers: {}, applyReviewers: { _ in }, openCode: {})
        .frame(width: width, alignment: .topLeading).background(Color.white).environment(\.colorScheme, .light)
      let (window, host) = host(view, width: width)
      defer { window.contentView = nil; window.close() }
      try await settle(host)
      XCTAssertEqual(host.bounds.width, width, accuracy: 1)
      XCTAssertGreaterThan(host.fittingSize.height, 140)
      if let folder = ProcessInfo.processInfo.environment["SHIPIOS_PR_OVERVIEW_RENDER_DIR"] {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
          .write(to: URL(fileURLWithPath: folder).appendingPathComponent("overview-\(Int(width)).png"))
      }
    }
  }

  func testOldHeadOrOtherPRCannotPublishChecksAndCommentsAsCurrent() async throws {
    let (root, service) = try await fixture()
    let metadata = try await service.mergeSnapshot(for: request, at: root)
    let discussion = try await service.discussion(for: request, at: root)
    let checks = GitHubPRChecksSnapshot(headRevision: head, checks: [], complete: true)
    func value(_ metadata: GitHubPRMergeSnapshot?, _ discussion: GitHubPRDiscussionSnapshot?, _ checks: GitHubPRChecksSnapshot?) -> GitHubPROverviewPresentation {
      .init(request: request, metadata: metadata, loading: false, error: nil,
        discussion: discussion, discussionError: nil, checks: checks, checksLoading: false, checksError: nil)
    }
    XCTAssertEqual(value(metadata, discussion, checks).comments, .value("无评论", .normal))
    XCTAssertEqual(value(metadata, discussion, checks).checks, .value("没有 CI 检查", .normal))
    var changed = metadata.details; changed.headRefOid = String(repeating: "b", count: 40)
    let newMetadata = GitHubPRMergeSnapshot(details: changed, repository: metadata.repository,
      isAuthor: true, allowedMethods: metadata.allowedMethods, isAutoMergeEnabled: false)
    XCTAssertEqual(value(newMetadata, discussion, checks).comments, .loading)
    XCTAssertEqual(value(newMetadata, discussion, checks).checks, .loading)
    var otherPR = discussion
    otherPR = .init(requestURL: "https://github.com/sample/project/pull/43", nodeID: otherPR.nodeID,
      viewer: otherPR.viewer, author: otherPR.author, state: otherPR.state, head: head,
      comments: otherPR.comments, threads: otherPR.threads, events: otherPR.events, omittedTypes: [])
    XCTAssertEqual(value(metadata, otherPR, checks).comments, .loading)
    XCTAssertEqual(value(nil, discussion, checks).comments, .loading)
    XCTAssertEqual(value(nil, discussion, checks).checks, .loading)
    changed.headRefOid = "invalid"
    let invalid = GitHubPRMergeSnapshot(details: changed, repository: metadata.repository,
      isAuthor: true, allowedMethods: metadata.allowedMethods, isAutoMergeEnabled: false)
    XCTAssertEqual(value(invalid, discussion, checks).comments, .failed)
    XCTAssertEqual(value(invalid, discussion, checks).checks, .failed)
  }

  func testMetadataAndIndependentFailuresDoNotBecomeEmptySuccessOrOverrideEachOther() async throws {
    let (root, service) = try await fixture()
    let metadata = try await service.mergeSnapshot(for: request, at: root)
    let discussion = try await service.discussion(for: request, at: root)
    let checks = GitHubPRChecksSnapshot(headRevision: head, checks: [], complete: true)
    let failed = GitHubPROverviewPresentation(request: request, metadata: nil, loading: false, error: "Unavailable",
      discussion: nil, discussionError: nil, checks: nil, checksLoading: false, checksError: nil)
    XCTAssertEqual(failed.comments, .failed); XCTAssertEqual(failed.checks, .failed)
    let commentsFailed = GitHubPROverviewPresentation(request: request, metadata: metadata, loading: false, error: nil,
      discussion: discussion, discussionError: "Unavailable", checks: checks, checksLoading: false, checksError: nil)
    XCTAssertEqual(commentsFailed.comments, .failed); XCTAssertEqual(commentsFailed.checks, .value("没有 CI 检查", .normal))
    let checksFailed = GitHubPROverviewPresentation(request: request, metadata: metadata, loading: false, error: nil,
      discussion: discussion, discussionError: nil, checks: nil, checksLoading: false, checksError: "Unavailable")
    XCTAssertEqual(checksFailed.comments, .value("无评论", .normal)); XCTAssertEqual(checksFailed.checks, .failed)
    XCTAssertEqual(checksFailed.checksIcon, "exclamationmark.circle")
    var partial = discussion; partial.isActivityPartial = true
    let partialValue = GitHubPROverviewPresentation(request: request, metadata: metadata, loading: false, error: nil,
      discussion: partial, discussionError: nil, checks: checks, checksLoading: true, checksError: nil)
    XCTAssertEqual(partialValue.comments, .value("已载入 0 条评论", .normal)); XCTAssertEqual(partialValue.checks, .loading)
  }

  func testOverviewCheckValuesUseFailuresBeforePendingAndNeverCallIncompleteListsSuccessful() async throws {
    let (root, service) = try await fixture()
    let metadata = try await service.mergeSnapshot(for: request, at: root)
    for (statuses, complete, label, tone): ([GitHubPRCheckStatus], Bool, String, GitHubPROverviewPresentation.Tone) in [
      ([], true, "没有 CI 检查", .normal), ([.passing, .neutral, .skipped], true, "检查成功", .success),
      ([.passing], false, "检查进行中", .pending), ([.unknown], true, "检查进行中", .pending),
      ([.pending], true, "检查进行中", .pending), ([.failing, .pending], true, "检查失败", .failure)] {
      let checks = GitHubPRChecksSnapshot(headRevision: head, checks: statuses.enumerated().map {
        .init(id: String($0.offset), name: "CI", status: $0.element, link: nil, description: nil)
      }, complete: complete)
      let value = GitHubPROverviewPresentation(request: request, metadata: metadata, loading: false, error: nil,
        discussion: nil, discussionError: nil, checks: checks, checksLoading: false, checksError: nil)
      XCTAssertEqual(value.checks, .value(label, tone))
    }
  }

  private struct LayoutProbe: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView {
      let field = NSView()
      field.identifier = .init(name); return field
    }
    func updateNSView(_ field: NSView, context: Context) { }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
      .init(width: proposal.width ?? 80, height: proposal.height ?? 20)
    }
  }
  func testNativePropertyLayoutHidesLabelsAt383AndAlignsValuesAt384WithoutDuplicatingControls() async throws {
    for inset: CGFloat in [0, 8] {
      for width: CGFloat in [284, 383, 384, 700] {
        let content = PullRequestOverviewRowLayout(containerInlineInset: inset) {
          LayoutProbe(name: "icon")
          LayoutProbe(name: "label").clipped()
          LayoutProbe(name: "value")
        }.frame(width: width - inset * 2).padding(.horizontal, inset)
        let (window, host) = host(content, width: width)
        defer { window.contentView = nil; window.close() }
        try await settle(host)
        func fields(_ view: NSView) -> [NSView] {
          (["icon", "label", "value"].contains(view.identifier?.rawValue ?? "") ? [view] : []) + view.subviews.flatMap(fields)
        }
        let all = fields(host)
        XCTAssertEqual(all.count, 3, "Responsive layout must not duplicate any input/control")
        let value = try XCTUnwrap(all.first { $0.identifier?.rawValue == "value" })
        let label = try XCTUnwrap(all.first { $0.identifier?.rawValue == "label" })
        XCTAssertEqual(value.convert(value.bounds, to: host).minX, (width >= 384 ? 132 : 28) + inset, accuracy: 1)
        XCTAssertEqual(label.bounds.width, width >= 384 ? 96 : 0, accuracy: 1)
        XCTAssertEqual(label.bounds.height == 0, width < 384)
      }
    }
  }
}
