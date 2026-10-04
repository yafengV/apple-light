import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

private actor PRMediaResponseGate {
  private var pending: [String: CheckedContinuation<GitHubPRCommentMediaLoader.Payload, Error>] = [:]
  func load(_ media: GitHubPRCommentMedia) async throws -> GitHubPRCommentMediaLoader.Payload {
    try await withCheckedThrowingContinuation { pending[media.url.lastPathComponent] = $0 }
  }
  func waiting(_ id: String) -> Bool { pending[id] != nil }
  func resolve(_ id: String, _ payload: GitHubPRCommentMediaLoader.Payload) { pending.removeValue(forKey: id)?.resume(returning: payload) }
}

@MainActor final class PRCommentMediaPresentationTests: XCTestCase {
  private struct Anchor: NSViewRepresentable {
    let capture: (NSView) -> Void
    func makeNSView(context: Context) -> NSView { let view = NSView(); capture(view); return view }
    func updateNSView(_ view: NSView, context: Context) {}
  }
  private func media(_ id: String = "fixture", kind: GitHubPRCommentMedia.Kind = .image) -> GitHubPRCommentMedia {
    .init(url: URL(string: "https://github.com/user-attachments/assets/" + id)!, kind: kind, alt: "Chart", title: "Image title")
  }
  private func png(width: Int = 100, height: Int = 50) throws -> Data {
    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.bitmapData?.initialize(repeating: 230, count: bitmap.bytesPerRow * height)
    return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
  }
  private func facts() throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/pr_comment_media_reference.json")
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  }
  private func settle(_ root: NSView) async throws {
    for _ in 0..<6 { root.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
  }
  private func wait(_ id: String, gate: PRMediaResponseGate) async throws {
    for _ in 0..<100 { if await gate.waiting(id) { return }; try await Task.sleep(for: .milliseconds(5)) }
    XCTFail("Response gate did not receive " + id)
  }
  private final class Capture {
    var view: NSView?
    var bounds: CGRect { view?.bounds ?? .zero }
  }
  private func host<V: View>(_ view: V, width: CGFloat = 500, height: CGFloat = 800) async throws -> (NSWindow, NSHostingView<AnyView>, Capture) {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
    let captured = Capture(); var preferences = AppearancePreferences(); preferences.theme = "light"
    let root = NSHostingView(rootView: AnyView(VStack(alignment: .leading, spacing: 0) {
      view.fixedSize(horizontal: false, vertical: true).background { Anchor { captured.view = $0 } }
      Spacer(minLength: 0)
    }.frame(width: width, height: height, alignment: .topLeading).environment(\.appAppearance, preferences)))
    root.sizingOptions = []; window.contentView = root; try await settle(root)
    addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
    _ = try XCTUnwrap(captured.view); return (window, root, captured)
  }
  private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
    (view as? T) ?? view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
  }
  func testActualReferenceMIMEBranchesAndExternalTargets() async throws {
    let reference = try facts(), rows = try XCTUnwrap(reference["branches"] as? [[String: Any]])
    XCTAssertEqual(reference["playableMedia"] as? Bool, false); XCTAssertEqual(rows.count, 10)
    let imageData = try png()
    let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"50\"><rect width=\"100\" height=\"50\" fill=\"red\"/></svg>".utf8)
    for row in rows where row["loading"] as? Bool != true {
      let name = try XCTUnwrap(row["name"] as? String), mime = try XCTUnwrap(row["mime"] as? String)
      let m = media(kind: row["kind"] as? String == "video" ? .video : .image), state = PRCommentMediaPresentation()
      let failed = row["failed"] as? Bool == true, fetchError = row["status"] as? String == "error"
      await state.load(m) { _ in
        if fetchError { throw AgentFailure(message: "fixture") }
        return .init(data: failed ? Data([0]) : mime == "image/svg+xml" ? svg : imageData, mimeType: mime)
      }
      switch state.phase {
      case .image: XCTAssertEqual(row["result"] as? String, "image", name); XCTAssertFalse(state.canOpen(m))
      case .unavailable(let external):
        XCTAssertEqual(row["result"] as? String, "unavailable", name)
        XCTAssertEqual(external, row["external"] as? Bool, name)
        var normal: URL?, outside: URL?
        state.open(m, normally: { normal = $0 }, externally: { outside = $0 })
        XCTAssertEqual(external ? outside : normal, m.url, name); XCTAssertNil(external ? normal : outside, name)
      case .loading: XCTFail("Unexpected loading state: " + name)
      }
    }
  }
  func testSlowOldResponseCannotReplaceNewMediaAndCancelPreventsOpen() async throws {
    let gate = PRMediaResponseGate(), state = PRCommentMediaPresentation(), a = media("a"), b = media("b", kind: .video)
    let first = Task { await state.load(a, using: { try await gate.load($0) }) }; try await wait("a", gate: gate)
    let second = Task { await state.load(b, using: { try await gate.load($0) }) }; try await wait("b", gate: gate)
    await gate.resolve("b", .init(data: Data([0]), mimeType: "video/mp4")); await second.value
    XCTAssertTrue(state.canOpen(b)); XCTAssertFalse(state.canOpen(a))
    await gate.resolve("a", .init(data: try png(), mimeType: "image/png")); await first.value
    guard case .unavailable(let external) = state.phase else { return XCTFail("Old response replaced current video fallback") }
    XCTAssertTrue(external)
    state.cancel(); XCTAssertFalse(state.canOpen(b))
    var called = false; state.open(b, normally: { _ in called = true }, externally: { _ in called = true }); XCTAssertFalse(called)
  }
  func testCancelledLoadAndChangedKindDoNotKeepPreviousPreview() async throws {
    let gate = PRMediaResponseGate(), state = PRCommentMediaPresentation(), m = media()
    let request = Task { await state.load(m, using: { try await gate.load($0) }) }; try await wait("fixture", gate: gate)
    request.cancel(); await gate.resolve("fixture", .init(data: try png(), mimeType: "image/png")); await request.value
    guard case .loading = state.phase else { return XCTFail("Cancelled response must not display a preview") }
    XCTAssertFalse(state.canOpen(m))
    await state.load(media(kind: .video)) { _ in .init(data: Data([0]), mimeType: "application/octet-stream") }
    XCTAssertFalse(state.canOpen(m)); XCTAssertTrue(state.canOpen(media(kind: .video)))
    let imageData = try png()
    await state.load(m) { _ in .init(data: imageData, mimeType: "application/octet-stream") }
    guard case .image = state.phase else { return XCTFail("Changing video to image must decode the current response") }
  }
  func testResponseMIMEIsNormalizedBeforeVideoImageSelection() async throws {
    let state = PRCommentMediaPresentation(), payload = GitHubPRCommentMediaLoader.Payload(data: try png(), mimeType: " IMAGE/PNG; charset=binary ")
    await state.load(media(kind: .video)) { _ in payload }
    guard case .image = state.phase else { return XCTFail("Case-insensitive image MIME should preview in a video directive") }
  }
  func testMountedLoadingFallbackButtonAndExternalRouteHaveReferenceSizes() async throws {
    let gate = PRMediaResponseGate(), m = media(kind: .video)
    var normal: URL?, external: URL?
    let (window, root, body) = try await host(TaskPullRequestCommentMediaView(media: m, open: { normal = $0 },
      openExternally: { external = $0 }, load: { try await gate.load($0) }))
    try await wait("fixture", gate: gate)
    XCTAssertEqual(body.bounds.width, 160, accuracy: 1); XCTAssertEqual(body.bounds.height, 96, accuracy: 1)
    XCTAssertNil(find(NSImageView.self, in: root)); XCTAssertNil(find(AppearanceActionButton.Control.self, in: root))
    await gate.resolve("fixture", .init(data: Data([0]), mimeType: "video/mp4")); try await settle(root)
    XCTAssertEqual(body.bounds.width, 160, accuracy: 1); XCTAssertEqual(body.bounds.height, 120, accuracy: 1)
    let button = try XCTUnwrap(find(AppearanceActionButton.Control.self, in: root))
    XCTAssertTrue(button.outlinedPill); XCTAssertEqual(button.bounds.height, 24, accuracy: 1); XCTAssertEqual(button.font?.pointSize, 13)
    XCTAssertTrue(window.makeFirstResponder(button)); XCTAssertTrue(button.accessibilityPerformPress())
    XCTAssertEqual(external, m.url); XCTAssertNil(normal)
    XCTAssertFalse(window.isVisible, "Native tests must not foreground a window")
  }
  func testMountedFailureUsesNormalLinkRouteAndTeardownRetiresButton() async throws {
    let m = media(kind: .video); var normal: URL?, external: URL?
    let (window, root, _) = try await host(TaskPullRequestCommentMediaView(media: m, open: { normal = $0 },
      openExternally: { external = $0 }, load: { _ in throw AgentFailure(message: "fixture") }))
    let button = try XCTUnwrap(find(AppearanceActionButton.Control.self, in: root))
    XCTAssertTrue(button.accessibilityPerformPress()); XCTAssertEqual(normal, m.url); XCTAssertNil(external)
    window.contentView = nil; try await settle(root)
    // Explicitly dismantle the retained control to cover callbacks surviving a mounted branch.
    PRCommentMediaOpenButton.dismantleNSView(button, coordinator: ())
    XCTAssertFalse(button.accessibilityPerformPress()); XCTAssertNil(button.activate)
  }
  func testMountedImageKeepsIntrinsicSizeTitleAndAnimatedImageSupport() async throws {
    let data = try png()
    let (_, root, body) = try await host(TaskPullRequestCommentMediaView(media: media(), open: { _ in }, load: { _ in .init(data: data, mimeType: "image/png") }))
    let image = try XCTUnwrap(find(NSImageView.self, in: root))
    XCTAssertEqual(body.bounds.width, 100, accuracy: 1); XCTAssertEqual(body.bounds.height, 74, accuracy: 1)
    XCTAssertEqual(image.bounds.size, .init(width: 100, height: 50)); XCTAssertTrue(image.animates)
    XCTAssertEqual(image.accessibilityLabel(), "Chart"); XCTAssertEqual(image.toolTip, "Image title")
    XCTAssertTrue(image.layer?.masksToBounds == true)
    let surface = try XCTUnwrap(find(PRCommentMediaImageView.Surface.self, in: root))
    XCTAssertTrue(try XCTUnwrap(surface.imageMask.path).contains(.init(x: 2.5, y: 2.5)))
    XCTAssertFalse(try XCTUnwrap(surface.imageMask.path).contains(.zero))
    XCTAssertEqual(surface.shadowLayers.map(\.shadowRadius), [3, 2])
    XCTAssertEqual(surface.shadowLayers.map(\.shadowOffset), [.init(width: 0, height: -4), .init(width: 0, height: -2)])
    XCTAssertEqual(try XCTUnwrap(surface.shadowLayers[0].shadowPath).boundingBoxOfPath, CGRect(x: 1, y: 1, width: 98, height: 48))
    XCTAssertEqual(try XCTUnwrap(surface.shadowLayers[1].shadowPath).boundingBoxOfPath, CGRect(x: 2, y: 2, width: 96, height: 46))
  }
  func testMountedTallImageRespondsToWindowHeightAndKeepsAspectRatio() async throws {
    let data = try png(width: 800, height: 1200)
    let (window, root, body) = try await host(TaskPullRequestCommentMediaView(media: media(), open: { _ in }, load: { _ in .init(data: data, mimeType: "image/png") }))
    let image = try XCTUnwrap(find(NSImageView.self, in: root))
    XCTAssertEqual(image.bounds.height, 560, accuracy: 1); XCTAssertEqual(image.bounds.width, 560 * 2 / 3, accuracy: 1)
    XCTAssertEqual(body.bounds.height, 584, accuracy: 1)
    window.setContentSize(.init(width: 500, height: 300)); try await settle(root)
    XCTAssertEqual(window.contentLayoutRect.height, 300, accuracy: 1)
    let resized = try XCTUnwrap(find(NSImageView.self, in: root))
    XCTAssertEqual(resized.bounds.height, 210, accuracy: 1); XCTAssertEqual(resized.bounds.width, 140, accuracy: 1)
    XCTAssertEqual(body.bounds.height, 234, accuracy: 1)
  }
  func testImageLimitsKeepZeroAndUnboundedProposalsFiniteWithoutUpscaling() {
    XCTAssertEqual(PRCommentMediaImageMetrics.size(intrinsic: .init(width: 100, height: 50), width: nil, viewportHeight: 2000), .init(width: 100, height: 50))
    XCTAssertEqual(PRCommentMediaImageMetrics.size(intrinsic: .init(width: 2000, height: 2000), width: .infinity, viewportHeight: .infinity), .init(width: 640, height: 640))
    XCTAssertEqual(PRCommentMediaImageMetrics.size(intrinsic: .init(width: 100, height: 50), width: 0, viewportHeight: 800), .zero)
    XCTAssertEqual(PRCommentMediaImageMetrics.size(intrinsic: .init(width: CGFloat.nan, height: 50), width: 100, viewportHeight: 800), .zero)
  }
  func testNativeMediaButtonRespectsOwningWindowModalAndLatestAvailability() {
    final class Scope: WindowModalScope { let modalRoot = NSView(); var modalScopeActive = true }
    let scope = Scope(), root = NSView(frame: .init(x: 0, y: 0, width: 200, height: 100))
    let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = root
    let button = AppearanceActionButton.Control(frame: .init(x: 0, y: 0, width: 120, height: 24))
    root.addSubview(button); root.addSubview(scope.modalRoot)
    var allowed = true, count = 0; button.canAct = { allowed }; button.activate = { count += 1 }
    defer { WindowModalInteraction.remove(scope, from: window); window.contentView = nil; window.close() }
    XCTAssertTrue(button.accessibilityPerformPress()); XCTAssertEqual(count, 1)
    WindowModalInteraction.install(scope, in: window)
    XCTAssertFalse(button.accessibilityPerformPress()); XCTAssertEqual(count, 1)
    scope.modalScopeActive = false; allowed = false
    XCTAssertFalse(button.accessibilityPerformPress()); XCTAssertEqual(count, 1)
  }
  func testCornerPathAndShadowMasksStayFiniteDuringZeroTinyAndRestoredFrames() {
    let shape = PRCommentMediaCornerShape(radius: 12.5), surface = PRCommentMediaImageView.Surface()
    for size in [CGSize.zero, .init(width: 1, height: 1), .init(width: 0, height: 100), .init(width: 160, height: 96), .zero] {
      let rect = CGRect(origin: .zero, size: size), path = shape.cgPath(in: rect)
      if size.width == 0 || size.height == 0 {
        XCTAssertTrue(path.isEmpty); XCTAssertTrue(shape.path(in: rect).isEmpty)
      }
      else { XCTAssertEqual(path.boundingBoxOfPath.minX, 0, accuracy: 0.0001); XCTAssertEqual(path.boundingBoxOfPath.maxX, size.width, accuracy: 0.0001) }
      surface.frame = rect; surface.needsLayout = true; surface.layoutSubtreeIfNeeded()
      for mask in [surface.imageMask.path] + surface.shadowLayers.map(\.shadowPath) {
        guard let mask, !mask.isEmpty else { continue }
        XCTAssertTrue(mask.boundingBoxOfPath.origin.x.isFinite); XCTAssertTrue(mask.boundingBoxOfPath.origin.y.isFinite)
        XCTAssertTrue(mask.boundingBoxOfPath.width.isFinite); XCTAssertTrue(mask.boundingBoxOfPath.height.isFinite)
      }
    }
    XCTAssertTrue(shape.cgPath(in: .init(x: CGFloat.nan, y: 0, width: 100, height: 100)).isEmpty)
    XCTAssertTrue(shape.cgPath(in: .init(x: 0, y: 0, width: CGFloat.infinity, height: 100)).isEmpty)
  }

  func testViewportReaderRetargetsWindowsAndIgnoresDetachedCallbacks() async throws {
    let reader = PRCommentMediaViewport.Reader(frame: .init(x: 0, y: 0, width: 20, height: 20))
    let a = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
    let b = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
    a.isReleasedWhenClosed = false; b.isReleasedWhenClosed = false
    let ar = NSView(frame: .init(x: 0, y: 0, width: 300, height: 400)), br = NSView(frame: .init(x: 0, y: 0, width: 300, height: 200))
    a.contentView = ar; b.contentView = br
    defer { reader.detach(); reader.changed = nil; a.contentView = nil; b.contentView = nil; a.close(); b.close() }
    var values: [CGFloat] = []; reader.changed = { values.append($0) }
    ar.addSubview(reader); try await settle(ar); XCTAssertEqual(values.last, 400)
    reader.removeFromSuperview(); br.addSubview(reader); try await settle(br); XCTAssertEqual(values.last, 200)
    let count = values.count; a.setContentSize(.init(width: 300, height: 500)); try await settle(br)
    XCTAssertEqual(values.count, count)
    b.setContentSize(.init(width: 300, height: 300)); try await settle(br); XCTAssertEqual(values.last, 300)
    PRCommentMediaViewport.dismantleNSView(reader, coordinator: ())
    let detachedCount = values.count; b.setContentSize(.init(width: 300, height: 350)); try await settle(br)
    XCTAssertEqual(values.count, detachedCount)
  }

  func testMarkdownAndHTMLImageTitlesSurviveParsing() {
    let markdown = "![Chart](https://user-images.githubusercontent.com/a.png \"A title\")"
    guard case .media(let a) = MessageDocument.parse(markdown, githubMedia: true).first?.kind else { return XCTFail("Image") }
    XCTAssertEqual(a.title, "A title")
    let html = "<img src=\"https://user-images.githubusercontent.com/a.png\" alt=\"Chart\" title=\"A &amp; B\">"
    XCTAssertEqual(GitHubPRCommentMedia.html(html)?.title, "A & B")
  }
}
