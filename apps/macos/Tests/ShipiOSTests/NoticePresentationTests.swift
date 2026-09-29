import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import ShipiOS

@MainActor final class NoticePresentationTests: XCTestCase {
  func testActualProviderReplacementReuseAndPoliteRegion() throws {
    let f = try fixture(), provider = try dict(f["provider"])
    XCTAssertEqual(f["initialSHA256"] as? String, "01c04b2e5a96e5dd4c97e02ffa183f571a55bef7a221abd99404246c430f2212")
    XCTAssertEqual(provider["staleCloseIgnored"] as? Bool, true)
    let events = try XCTUnwrap(provider["events"] as? [[String: Any]])
    XCTAssertEqual(events.prefix(4).compactMap { $0["op"] as? String }, ["show", "show", "dismiss", "show"])
    XCTAssertEqual(events[0]["duration"] as? Int, 5000)
    XCTAssertEqual(events.last?["dismissible"] as? Bool, false)
    XCTAssertTrue((f["region"] as? String)?.contains("\"aria-relevant\":`additions text`") == true)
    let cases = try XCTUnwrap(f["cases"] as? [[String: Any]]); XCTAssertEqual(cases.count, 24)
    for sample in cases {
      XCTAssertEqual(sample["announce"] as? Bool, false)
      XCTAssertEqual(sample["actionsInline"] as? Bool, sample["description"] is NSNull)
      XCTAssertEqual(sample["closed"] as? Int, 1)
      XCTAssertEqual(sample["acted"] as? Int, (sample["hasAction"] as? Bool) == true ? 1 : 0)
      let props = try dict(try dict(sample["tree"])["props"])
      XCTAssertNil(props["role"], "The polite region owns announcements; cards are not assertive alerts")
    }
  }

  func testReplacementMovesToFrontAndStaleActionsAreRejected() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true
    store.library.tasks = [.init(id: "task", project: "", title: "Task", runIDs: [])]
    store.openSettings(.archived)
    store.notices.show(id: "old", title: "Old", level: .info, taskID: "task")
    let old = try XCTUnwrap(store.notices.items.first)
    store.notices.show(id: "other", title: "Other", level: .warning)
    store.notices.advance(by: 3)
    store.notices.show(id: "old", title: "Replacement", description: "detail", level: .success, taskID: "task")
    XCTAssertEqual(store.notices.items.map(\.id), ["old", "other"])
    XCTAssertNotEqual(store.notices.items.first?.generation, old.generation)
    XCTAssertEqual(store.notices.items.first?.remaining, 5)
    store.notices.dismiss(old.id, generation: old.generation)
    await store.openNoticeTask(old)
    XCTAssertEqual(store.destination, .settings)
    XCTAssertEqual(store.notices.items.first?.title, "Replacement")
    await store.openNoticeTask(try XCTUnwrap(store.notices.items.first))
    XCTAssertEqual(store.destination, .workspace)
    XCTAssertEqual(store.selectedTask?.id, "task")
    XCTAssertEqual(store.notices.items.map(\.id), ["other"])
  }

  func testAnnouncementsIgnoreTimersAndRemovalButIncludeFreshIdenticalText() throws {
    let notices = WorkspaceNotices(); var changes = NoticeAnnouncementChanges()
    notices.show(id: "a", title: "First", level: .info)
    notices.show(id: "b", title: "Second", description: "Detail", level: .success)
    XCTAssertEqual(changes.receive(notices.items.map(NoticeAnnouncement.init)), ["First", "Second\nDetail"])
    notices.advance(by: 1)
    XCTAssertEqual(changes.receive(notices.items.map(NoticeAnnouncement.init)), [])
    notices.dismiss("b")
    XCTAssertEqual(changes.receive(notices.items.map(NoticeAnnouncement.init)), [])
    notices.show(id: "a", title: "First", level: .info)
    XCTAssertEqual(changes.receive(notices.items.map(NoticeAnnouncement.init)), ["First"])
    var notice = try XCTUnwrap(notices.items.first); notice.description = "Updated"
    XCTAssertEqual(changes.receive([.init(notice)]), ["First\nUpdated"])
    XCTAssertEqual(changes.receive([.init(notice)]), [])
  }

  func testAnnouncementSourceNeverPostsForHiddenDetachedOrStoppedViews() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    var received: [String] = []
    let coordinator = NoticeAnnouncementSource.Coordinator { text, _ in received.append(text) }
    let source = NoticeAnnouncementSource.Source(); coordinator.attach(source)
    let notice = WorkspaceNotice(id: "a", title: "Hidden", level: .info, taskID: nil, remaining: 5)
    coordinator.stage([.init(notice)]); coordinator.flush()
    window.contentView = source; coordinator.flush()
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertFalse(window.isVisible); XCTAssertTrue(received.isEmpty)
    window.contentView = nil; coordinator.stop(); coordinator.stage([.init(notice)]); coordinator.flush()
    XCTAssertNil(source.coordinator); XCTAssertTrue(received.isEmpty)
    XCTAssertFalse(source.acceptsFirstResponder); XCTAssertNil(source.hitTest(.zero))
  }

  func testActualCSSCardSizesColorsAndCollapsedStackInOfflineDocument() async throws {
    let f = try fixture(), configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
    let web = WKWebView(frame: .init(x: 0, y: 0, width: 816, height: 500), configuration: configuration)
    defer { web.stopLoading() }
    let results = try await web.callAsyncJavaScript(#"""
      document.documentElement.dataset.codexWindowType='electron';
      const style=document.createElement('style');style.textContent=css;document.head.append(style);
      function render(n){if(n==null||typeof n==='boolean')return document.createTextNode('');if(typeof n==='string')return document.createTextNode(n);
        if(n.type==='Fragment'){const f=document.createDocumentFragment();(n.props.children??[]).forEach(c=>f.append(render(c)));return f}
        if(n.type==='Action')return render(action);
        const e=document.createElement(n.type==='Icon'?'span':n.type);const p=n.props;
        if(n.type==='Icon'){e.style.cssText='display:block;width:16px;height:16px'}
        if(p.className)e.className=p.className;
        for(const child of Array.isArray(p.children)?p.children:[p.children])e.append(render(child));return e;
      }
      function rgb(value){const e=document.createElement('span');e.style.color=`rgb(from ${value} r g b / alpha)`;document.body.append(e);const result=getComputedStyle(e).color;e.remove();return result}
      const results=[];for(const dark of [false,true]){document.documentElement.dataset.theme=dark?'dark':'light';
        for(const sample of cases){const wrapper=document.createElement('div');wrapper.className='_toast_1msoq_1';wrapper.append(render(sample.tree));document.body.append(wrapper);
          const card=wrapper.firstChild,s=getComputedStyle(card),r=card.getBoundingClientRect();
          const button=card.querySelector('button');results.push({dark,level:sample.level,description:sample.description,hasAction:sample.hasAction,height:r.height,width:r.width,font:s.fontSize,line:s.lineHeight,padding:s.paddingLeft,border:s.borderTopWidth,radius:s.borderRadius,color:rgb(s.color),background:rgb(s.backgroundColor),borderColor:rgb(s.borderTopColor),buttonHeight:button.getBoundingClientRect().height});wrapper.remove();}}
      return results;
      """#, arguments: ["css": f["css"]!, "cases": f["cases"]!, "action": f["action"]!], in: nil, contentWorld: .defaultClient) as? [[String: Any]]
    let values = try XCTUnwrap(results); XCTAssertEqual(values.count, 48)
    for value in values {
      XCTAssertEqual(value["font"] as? String, "14px"); XCTAssertEqual(value["line"] as? String, "21px")
      XCTAssertEqual(value["padding"] as? String, "8px"); XCTAssertEqual(value["border"] as? String, "1px")
      XCTAssertEqual(value["radius"] as? String, "15px"); XCTAssertEqual(value["buttonHeight"] as? Double, 24)
      let hasDescription = !(value["description"] is NSNull), hasText = (value["description"] as? String)?.isEmpty == false
      let expected = 42.0 + (hasText ? 21 : 0) + (hasDescription && value["hasAction"] as? Bool == true ? 32 : 0)
      XCTAssertEqual(value["height"] as? Double, expected, "\(value)")
      let level = try XCTUnwrap(["info": WorkspaceNotice.Level.info, "success": .success, "warning": .warning, "danger": .error][value["level"] as? String ?? ""])
      if level != .info {
        var appearance = AppearancePreferences(); appearance.theme = value["dark"] as? Bool == true ? "dark" : "light"
        let palette = NoticeCardColors(level: level, appearance: appearance)
        try assertColor(value["color"], palette.foreground)
        try assertColor(value["background"], palette.background)
        try assertColor(value["borderColor"], palette.border)
      }
    }
    XCTAssertNil(web.window)
  }

  func testCollapsedAndExpandedNaturalHeightExtents() {
    let closed = NoticeStackLayout(heights: [42, 84, 42, 120], expanded: false)
    XCTAssertEqual(closed.containerHeight(1), 42); XCTAssertEqual(closed.scale(1), 0.95)
    XCTAssertEqual(closed.offset(1), 8); XCTAssertEqual(closed.offset(2), 16)
    XCTAssertEqual(closed.visibleExtent(3), 88.85, accuracy: 0.001)
    let open = NoticeStackLayout(heights: [42, 84, 42, 120], expanded: true)
    XCTAssertEqual(open.offset(2), 142); XCTAssertEqual(open.containerHeight(1), 84)
    XCTAssertEqual(open.visibleExtent(3), 184); XCTAssertEqual(open.scale(2), 1)
    XCTAssertEqual(NoticeStackLayout(heights: [], expanded: false).visibleExtent(3), 0)
  }

  func testActualStackCSSUsesCenterOriginAndEightPointOffsets() async throws {
    let f = try fixture(), configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
    let web = WKWebView(frame: .init(x: 0, y: 0, width: 816, height: 500), configuration: configuration)
    defer { web.stopLoading() }
    let heights: [CGFloat] = [42, 63, 95, 42]
    let results = try await web.callAsyncJavaScript(#"""
      const style=document.createElement('style');style.textContent=css;document.head.append(style);
      const result=[];for(const expanded of [false,true]){
        const root=document.createElement('ol');root.setAttribute('data-sonner-toaster','');root.style.cssText='position:relative;width:300px;--gap:8px;';document.body.append(root);
        let offset=0;for(let index=0;index<heights.length;index++){
          const li=document.createElement('li');li.setAttribute('data-sonner-toast','');li.dataset.yPosition='top';li.dataset.xPosition='center';li.dataset.front=String(index===0);li.dataset.expanded=String(expanded);li.dataset.mounted='true';li.dataset.visible=String(index<3);li.dataset.styled='false';
          li.style.cssText=`transition:none;width:120px;--toasts-before:${index};--front-toast-height:${heights[0]}px;--initial-height:${heights[index]}px;--offset:${offset}px;`;
          const child=document.createElement('div');child.style.cssText=`height:${heights[index]}px;width:120px;`;li.append(child);root.append(li);offset+=heights[index]+8;
          const r=li.getBoundingClientRect(),c=child.getBoundingClientRect(),s=getComputedStyle(li),parent=root.getBoundingClientRect();
          result.push({expanded,index,top:r.top-parent.top,height:r.height,childHeight:c.height,opacity:s.opacity,pointer:s.pointerEvents});
        }root.remove();
      }return result;
      """#, arguments: ["css": f["stackCSS"]!, "heights": heights.map(Double.init)], in: nil, contentWorld: .defaultClient) as? [[String: Any]]
    XCTAssertEqual(results?.count, 8)
    for result in try XCTUnwrap(results) {
      let index = try XCTUnwrap(result["index"] as? Int)
      let layout = NoticeStackLayout(heights: heights, expanded: result["expanded"] as? Bool == true)
      let scale = layout.scale(index)
      XCTAssertEqual(try XCTUnwrap(result["top"] as? Double), layout.offset(index) + layout.containerHeight(index) * (1 - scale) / 2, accuracy: 0.02)
      XCTAssertEqual(try XCTUnwrap(result["height"] as? Double), layout.containerHeight(index) * scale, accuracy: 0.02)
      XCTAssertEqual(try XCTUnwrap(result["childHeight"] as? Double), heights[index] * scale, accuracy: 0.02)
      XCTAssertEqual(result["opacity"] as? String, index < 3 ? "1" : "0")
      if index >= 3 { XCTAssertEqual(result["pointer"] as? String, "none") }
    }
    XCTAssertNil(web.window)
  }

  func testHiddenNativeCardsHugContentAndRespectViewportAndDescriptionRows() async throws {
    _ = NSApplication.shared
    let store = WorkspaceStore(dataRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let notices = [
      WorkspaceNotice(id: "plain", title: "Title", level: .info, taskID: nil, remaining: 5),
      WorkspaceNotice(id: "inline", title: "Title", level: .info, taskID: "task", remaining: 5),
      WorkspaceNotice(id: "empty", title: "Title", description: "", level: .success, taskID: "task", remaining: 5),
      WorkspaceNotice(id: "detail", title: "Title", description: "Detail\nline", level: .warning, taskID: nil, remaining: 5),
      WorkspaceNotice(id: "footer", title: "Title", description: "Detail\nline", level: .error, taskID: "task", remaining: 5),
      WorkspaceNotice(id: "long", title: String(repeating: "Long title ", count: 20), level: .info, taskID: nil, remaining: 5),
    ]
    var dimensions: [String: CGSize] = [:]
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    var appearance = AppearancePreferences(); appearance.theme = "light"
    let host = NSHostingView(rootView: NoticeMeasurementView(store: store, notices: notices, report: { dimensions = $0 })
      .environment(\.appAppearance, appearance))
    window.contentView = host; host.frame.size = .init(width: 600, height: 600)
    try await Task.sleep(for: .milliseconds(180)); host.layoutSubtreeIfNeeded()
    XCTAssertEqual(dimensions.count, 6)
    for (id, height) in [("plain", 42.0), ("inline", 42.0), ("empty", 74.0), ("detail", 63.0), ("footer", 95.0)] {
      XCTAssertEqual(try XCTUnwrap(dimensions[id]).height, height, accuracy: 0.1, id)
      XCTAssertLessThan(try XCTUnwrap(dimensions[id]).width, 600, id)
    }
    XCTAssertGreaterThan(try XCTUnwrap(dimensions["inline"]).width, try XCTUnwrap(dimensions["plain"]).width)
    XCTAssertEqual(try XCTUnwrap(dimensions["long"]).width, 600, accuracy: 0.1)
    XCTAssertGreaterThan(try XCTUnwrap(dimensions["long"]).height, 42)
    XCTAssertFalse(window.isVisible); XCTAssertNil(window.attachedSheet)
    XCTAssertEqual(NoticeTextLayout.description("  Detail\n\tline\r "), "Detail line")
    XCTAssertEqual(NoticeTextLayout.description("a\u{00A0}b"), "a\u{00A0}b")
  }

  func testPoliteAnnouncementsCoalesceAndStopUsingOnlySimulatedVisibility() async throws {
    _ = NSApplication.shared
    let window = NoticeSimulatedVisibilityWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    var received: [String] = [], priorities: [NSAccessibilityPriorityLevel] = []
    let coordinator = NoticeAnnouncementSource.Coordinator { text, priority in received.append(text); priorities.append(priority) }
    let source = NoticeAnnouncementSource.Source(); coordinator.attach(source); window.contentView = source
    let notices = WorkspaceNotices(); notices.show(id: "a", title: "Initial", level: .info)
    coordinator.stage(notices.items.map(NoticeAnnouncement.init)); coordinator.flush()
    XCTAssertTrue(received.isEmpty)
    // This overrides a property for the injected test sink; the window is never
    // shown, and no NSAccessibility notification or desktop event is posted.
    window.simulatedVisible = true; coordinator.flush()
    XCTAssertEqual(received, ["Initial"]); XCTAssertEqual(priorities, [.low])
    notices.advance(by: 1); coordinator.stage(notices.items.map(NoticeAnnouncement.init)); coordinator.flush()
    XCTAssertEqual(received, ["Initial"])
    window.simulatedVisible = false
    notices.show(id: "expired", title: "Never presented", level: .info)
    coordinator.stage(notices.items.map(NoticeAnnouncement.init)); notices.advance(by: 5)
    notices.show(id: "new", title: "Newest", description: "Detail", level: .info)
    coordinator.stage(notices.items.map(NoticeAnnouncement.init))
    window.simulatedVisible = true; coordinator.flush()
    XCTAssertEqual(received, ["Initial", "Newest\nDetail"])
    source.isHidden = true; notices.show(id: "hidden", title: "Hidden", level: .info)
    coordinator.stage(notices.items.map(NoticeAnnouncement.init)); coordinator.flush()
    XCTAssertEqual(received.count, 2)
    source.isHidden = false; coordinator.flush(); XCTAssertEqual(received.last, "Hidden")
    notices.show(id: "queued", title: "Queued", level: .info)
    coordinator.stage(notices.items.map(NoticeAnnouncement.init)); coordinator.stop()
    try await Task.sleep(for: .milliseconds(20)); XCTAssertEqual(received.count, 3)
    XCTAssertNil(source.coordinator)
  }

  private func fixture() throws -> [String: Any] {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "notice_card_reference", withExtension: "json", subdirectory: "Fixtures"))
    return try dict(JSONSerialization.jsonObject(with: Data(contentsOf: url)))
  }
  private func dict(_ value: Any?) throws -> [String: Any] { try XCTUnwrap(value as? [String: Any]) }
  private func assertColor(_ value: Any?, _ color: AppearanceRGBA, file: StaticString = #filePath, line: UInt = #line) throws {
    let css = try XCTUnwrap(value as? String, file: file, line: line)
    let regex = try NSRegularExpression(pattern: "[0-9]+(?:\\.[0-9]+)?")
    var numbers = regex.matches(in: css, range: NSRange(css.startIndex..., in: css)).compactMap { Range($0.range, in: css).flatMap { Double(css[$0]) } }
    XCTAssertTrue(numbers.count == 3 || numbers.count == 4, css, file: file, line: line)
    guard numbers.count >= 3 else { return }
    if !css.hasPrefix("color(") { for index in 0..<3 { numbers[index] /= 255 } }
    let expected = [Double(color.red) / 255, Double(color.green) / 255, Double(color.blue) / 255, color.alpha]
    if numbers.count == 3 { numbers.append(1) }
    for index in 0..<4 { XCTAssertEqual(numbers[index], expected[index], accuracy: 0.00001, css, file: file, line: line) }
  }
}

private final class NoticeSimulatedVisibilityWindow: NSWindow {
  var simulatedVisible = false
  override var isVisible: Bool { simulatedVisible }
}
private struct NoticeMeasurementView: View {
  let store: WorkspaceStore
  let notices: [WorkspaceNotice]
  let report: ([String: CGSize]) -> Void
  @FocusState private var focused: String?
  var body: some View {
    VStack {
      ForEach(notices) { notice in
        WorkspaceNoticeCard(store: store, notice: notice, focused: $focused)
          .background(GeometryReader { proxy in Color.clear.preference(key: NoticeMeasurementKey.self, value: [notice.id: proxy.size]) })
      }
    }.frame(width: 600).onPreferenceChange(NoticeMeasurementKey.self, perform: report)
  }
}
private struct NoticeMeasurementKey: PreferenceKey {
  static var defaultValue: [String: CGSize] = [:]
  static func reduce(value: inout [String: CGSize], nextValue: () -> [String: CGSize]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}
