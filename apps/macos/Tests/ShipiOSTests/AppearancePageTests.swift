import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import ShipiOS

@MainActor final class AppearancePageTests: XCTestCase {
  func testHistoricalDistributionLayoutVariantsAndDiffExample() throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "appearance_layout_reference", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    XCTAssertEqual(fixture["settingsSHA256"] as? String, "3a2ff568faaa71fa98cde8ca59a04d525baf13ce81a470ea8ae72c5283800753")
    let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]]); XCTAssertEqual(cases.count, 24)
    for sample in cases {
      let mode = AppearanceMode(preference: try XCTUnwrap(sample["mode"] as? String))
      XCTAssertEqual(mode.variants.map(\.rawValue), sample["variants"] as? [String])
      let options = try XCTUnwrap(sample["themeOptions"] as? [[String: Any]])
      XCTAssertEqual(options.compactMap { $0["mode"] as? String }, AppearanceMode.allCases.map(\.rawValue))
      XCTAssertEqual(options.filter { $0["selected"] as? Bool == true }.compactMap { $0["mode"] as? String }, [mode.rawValue])
      let components = try XCTUnwrap(sample["pageComponents"] as? [String])
      XCTAssertLessThan(try XCTUnwrap(components.firstIndex(of: "Vo")), try XCTUnwrap(components.firstIndex(of: "aa")))
      XCTAssertEqual(components.contains("oa"), sample["local"] as? Bool)
      if components.contains("oa") {
        XCTAssertLessThan(try XCTUnwrap(components.firstIndex(of: "oa")), try XCTUnwrap(components.firstIndex(of: "aa")))
      }
      XCTAssertLessThan(try XCTUnwrap(components.firstIndex(of: "Jo")), try XCTUnwrap(components.firstIndex(of: "$o")))
      XCTAssertEqual(components.contains("es"), sample["local"] as? Bool == true && sample["flavor"] as? String == "STEPS_COMMANDS")
    }
    let example = try XCTUnwrap(fixture["example"] as? [String: [String: String]])
    XCTAssertEqual(example["old"]?["contents"], AppearanceDiffPreview.before)
    XCTAssertEqual(example["newFile"]?["contents"], AppearanceDiffPreview.after)
    XCTAssertEqual(example["old"]?["name"], AppearanceDiffPreview.path)
    XCTAssertEqual(AppearanceDiffPreview.left.map { String($0.text.dropFirst()) }.joined(separator: "\n") + "\n", AppearanceDiffPreview.before)
    XCTAssertEqual(AppearanceDiffPreview.right.map { String($0.text.dropFirst()) }.joined(separator: "\n") + "\n", AppearanceDiffPreview.after)
    XCTAssertEqual(AppearanceDiffPreview.diff.additions, 3); XCTAssertEqual(AppearanceDiffPreview.diff.deletions, 3)
  }

  func testNativeThemeRadioKeyboardWrapTabStopAndPersistence() async throws {
    let (store, root) = makeStore(); let (window, host) = try await page(store); defer { window.close() }
    let group = try XCTUnwrap(find(host, AppearanceModePicker.Group.self).first)
    XCTAssertEqual(group.accessibilityRole(), .radioGroup)
    XCTAssertEqual(group.radios.map { $0.accessibilityRole() }, [.radioButton, .radioButton, .radioButton])
    XCTAssertEqual(group.radios.filter(\.canBecomeKeyView).map(\.mode), [.system])
    XCTAssertTrue(window.makeFirstResponder(group.radios[0]))
    group.radios[0].keyDown(with: try key(123, window))
    XCTAssertEqual(store.appearance.theme, "dark"); XCTAssertTrue(window.firstResponder === group.radios[2])
    group.radios[2].keyDown(with: try key(124, window))
    XCTAssertEqual(store.appearance.theme, "system"); XCTAssertTrue(window.firstResponder === group.radios[0])
    XCTAssertTrue(group.radios[1].accessibilityPerformPress()); try await settle(host)
    XCTAssertEqual(store.appearance.theme, "light")
    XCTAssertEqual(group.radios.filter(\.canBecomeKeyView).map(\.mode), [.light])
    XCTAssertEqual(group.radios.map { ($0.accessibilityValue() as? NSNumber)?.intValue }, [0, 1, 0])
    XCTAssertEqual(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json")).appearance?.theme, "light")
    XCTAssertEqual(store.library.drafts["fixture"], "keep draft"); XCTAssertFalse(window.isVisible)
  }

  func testThemeOptionsAreDiscoverableInNativeAccessibilityTree() async throws {
    let (store, _) = makeStore(); let (window, host) = try await page(store); defer { window.close() }
    let group = try XCTUnwrap(find(host, AppearanceModePicker.Group.self).first)
    let options = NSAccessibility.unignoredChildren(from: group.subviews).compactMap { $0 as? AppearanceModePicker.Radio }
    XCTAssertEqual(options.map(\.mode), [.system, .light, .dark])
    XCTAssertEqual((group.accessibilityChildren() ?? []).compactMap { ($0 as? AppearanceModePicker.Radio)?.mode }, [.system, .light, .dark])
    XCTAssertEqual(options.map { $0.accessibilityLabel() }, ["系统", "浅色", "深色"])
    XCTAssertTrue(options.allSatisfy { $0.isAccessibilityElement() })
    XCTAssertTrue(options.allSatisfy { $0.isAccessibilityEnabled() })
    XCTAssertEqual(options.map { ($0.accessibilityValue() as? NSNumber)?.intValue }, [1, 0, 0])
    let light = try XCTUnwrap(options.first { $0.mode == .light })
    XCTAssertTrue(light.accessibilityPerformPress()); try await settle(host)
    XCTAssertEqual(store.appearance.theme, "light")
    XCTAssertEqual(options.map { ($0.accessibilityValue() as? NSNumber)?.intValue }, [0, 1, 0])
    XCTAssertTrue(window.firstResponder === light)
    store.restoringLibrary = true; try await settle(host)
    XCTAssertTrue(options.allSatisfy { !$0.isEnabled })
    XCTAssertTrue(options.allSatisfy { !$0.isAccessibilityEnabled() })
    XCTAssertFalse(light.accessibilityPerformPress()); XCTAssertEqual(store.appearance.theme, "light")
    XCTAssertEqual(store.library.drafts["fixture"], "keep draft")
  }

  func testRadioSaveFailureRestoringDisabledAndUnmountedCallbacksAreGuarded() async throws {
    let (store, root) = makeStore(); let (window, host) = try await page(store); defer { window.close() }
    let group = try XCTUnwrap(find(host, AppearanceModePicker.Group.self).first), owner = try XCTUnwrap(group.owner)
    let saved = store.appearance
    try FileManager.default.createDirectory(at: root.appendingPathComponent("workspace.json"), withIntermediateDirectories: true)
    XCTAssertTrue(group.radios[2].accessibilityPerformPress())
    XCTAssertEqual(store.appearance, saved); XCTAssertEqual(group.selected, .system); XCTAssertNotNil(store.generalSettingsError)
    XCTAssertTrue(window.firstResponder === group.radios[2])
    store.restoringLibrary = true
    XCTAssertFalse(owner.choose(.light, in: group)); try await settle(host)
    XCTAssertFalse(group.radios[1].isEnabled); XCTAssertFalse(window.firstResponder is AppearanceModePicker.Radio)
    store.restoringLibrary = false; try await settle(host)
    group.removeFromSuperview(); XCTAssertFalse(owner.choose(.light, in: group)); XCTAssertEqual(store.appearance, saved)
    XCTAssertFalse(window.isVisible)
  }

  func testFullHiddenPageModeVisibilityAndNoHorizontalPageOverflow() async throws {
    let (store, _) = makeStore(); let (window, host) = try await page(store); defer { window.close() }
    for mode in AppearanceMode.allCases {
      var next = store.appearance; next.theme = mode.rawValue; XCTAssertTrue(store.commitAppearance(next)); try await settle(host)
      let colors = find(host, AppearanceColorInput.Control.self), contrast = find(host, AppearanceContrastSlider.Control.self)
      XCTAssertEqual(colors.count, mode.variants.count * 3, mode.rawValue); XCTAssertEqual(contrast.count, mode.variants.count)
      let labels = Set(colors.compactMap { $0.field.accessibilityLabel() })
      for variant in mode.variants { XCTAssertTrue(labels.contains(variant == .dark ? "深色背景色" : "浅色背景色")) }
      XCTAssertEqual(find(host, AppearanceModePicker.Group.self).count, 1)
      XCTAssertEqual(find(host, WKWebView.self).count, 1)
      for width in [816.0, 550.0] {
        window.setContentSize(.init(width: width, height: 600)); host.frame.size = .init(width: width, height: 600); try await settle(host)
        let scrolls = find(host, NSScrollView.self).filter { ($0.documentView?.frame.height ?? 0) > $0.contentSize.height + 200 }
        XCTAssertEqual(scrolls.count, 1)
        let scroll = try XCTUnwrap(scrolls.first), document = try XCTUnwrap(scroll.documentView)
        XCTAssertLessThanOrEqual(document.frame.width, scroll.contentSize.width + 1)
        let picker = try XCTUnwrap(find(host, AppearanceModePicker.Group.self).first)
        XCTAssertEqual(picker.bounds.width, 272, accuracy: 0.001)
        XCTAssertEqual(picker.radios[0].cardRect.width / picker.radios[0].cardRect.height, 4 / 3, accuracy: 0.001)
        XCTAssertEqual(picker.radios[1].frame.minX - picker.radios[0].frame.maxX, 16, accuracy: 0.001)
        scroll.contentView.scroll(to: .init(x: 0, y: 400)); scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 400, accuracy: 1)
      }
    }
    XCTAssertFalse(window.isVisible)
  }

  func testSearchOnlyTargetsMountedVariantAndOldRouteDoesNotChangeTheme() throws {
    let (store, _) = makeStore()
    for mode in AppearanceMode.allCases {
      var next = store.appearance; next.theme = mode.rawValue; XCTAssertTrue(store.commitAppearance(next))
      for field in SettingsSearchField.allCases where field.appearanceVariant != nil && ![.uiFont, .codeFont, .importTheme, .exportTheme].contains(field) {
        let results = SettingsSearch.results(for: field.title, appearanceTheme: mode.rawValue)
        XCTAssertEqual(results.contains { $0.field == field }, mode.variants.contains(try XCTUnwrap(field.appearanceVariant)), field.rawValue)
        store.revealSetting(.init(page: .appearance, field: field))
        XCTAssertEqual(store.settingsSearchRequest?.result.field, mode.variants.contains(field.appearanceVariant!) ? field : nil)
        XCTAssertEqual(store.appearance.theme, mode.rawValue)
      }
    }
  }

  func testChangingModeUnmountsOldPopupAndRejectsItsPendingChoice() async throws {
    let (store, _) = makeStore(); var initial = store.appearance; initial.theme = "dark"; XCTAssertTrue(store.commitAppearance(initial))
    let (window, host) = try await page(store); defer { window.close() }
    let button = try XCTUnwrap(find(host, SettingsPopupMenuButton.Control.self).first { $0.accessibilityLabel() == "深色强调色" })
    let owner = try XCTUnwrap(button.owner); owner.toggle(button, keyboard: true); try await settle(host)
    XCTAssertNotNil(owner.popup)
    let group = try XCTUnwrap(find(host, AppearanceModePicker.Group.self).first)
    XCTAssertTrue(group.radios[1].accessibilityPerformPress()); try await settle(host)
    XCTAssertNil(owner.popup); XCTAssertEqual(store.appearance.theme, "light")
    let saved = store.appearance; owner.choose("custom", button: button)
    XCTAssertEqual(store.appearance, saved); XCTAssertTrue(window.firstResponder === group.radios[1])
    XCTAssertEqual(store.library.drafts["fixture"], "keep draft"); XCTAssertFalse(window.isVisible)
  }

  func testActualFullPageHighlightsAfterAsyncLoadAndUpdatesFontSizeWithoutReplacingWebView() async throws {
    let (store, _) = makeStore(); let (window, host) = try await page(store); defer { window.close() }
    let web = try XCTUnwrap(find(host, WKWebView.self).first); try await ready(web)
    var colored = 0
    for _ in 0..<100 {
      colored = (try await web.callAsyncJavaScript("return [...document.querySelectorAll('.code span')].filter(e=>e.style.color).length", in: nil, contentWorld: .page)) as? Int ?? 0
      if colored > 10 { break }; try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertGreaterThan(colored, 10)
    var next = store.appearance; next.codeSize = 18; next.light.codeFont = "Menlo"; next.dark.codeFont = "Menlo"
    XCTAssertTrue(store.commitAppearance(next)); try await settle(host)
    XCTAssertTrue(find(host, WKWebView.self).first === web)
    let style = try await web.callAsyncJavaScript("return {size:getComputedStyle(document.body).fontSize,family:getComputedStyle(document.body).fontFamily,line:getComputedStyle(document.body).lineHeight}", in: nil, contentWorld: .page) as? [String: String]
    XCTAssertEqual(style?["size"], "18px"); XCTAssertTrue(style?["family"]?.contains("Menlo") == true)
    XCTAssertEqual(try XCTUnwrap(Double((style?["line"] ?? "").replacingOccurrences(of: "px", with: ""))), 18 * 1.8, accuracy: 0.0001)
    XCTAssertFalse(window.isVisible)
  }

  func testArtworkInteriorPixelsMatchActualSVGInNoWindowCanvas() async throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "theme_card_reference_644", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let artwork = try XCTUnwrap(fixture["artwork"] as? [[String: Any]])
    let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); let web = WKWebView(frame: .zero, configuration: config)
    let points = [3, 10, 25, 40, 60, 76].flatMap { x in [3, 10, 19, 23, 27, 33, 43, 50, 57].map { [x, $0] } }
    for scale in 1...3 { for mode in AppearanceMode.allCases { for accent in ["#339cff", "#df3758"] {
      let names = mode == .system ? ["system-light", "system-dark"] : [mode.rawValue]
      let trees = try names.map { name in try XCTUnwrap(artwork.first { $0["name"] as? String == name }?["tree"]) }
      let expected = try await web.callAsyncJavaScript(#"""
        const names={clipPath:'clip-path',strokeWidth:'stroke-width',strokeOpacity:'stroke-opacity',fillOpacity:'fill-opacity',shapeRendering:'shape-rendering',colorInterpolationFilters:'color-interpolation-filters',floodOpacity:'flood-opacity'};
        function build(tree){const node=document.createElementNS('http://www.w3.org/2000/svg',tree.type);
          for(const [key,value] of Object.entries(tree.props??{})){if(key==='children')continue;node.setAttribute(names[key]??key,value==='currentColor'?accent:value)}
          for(const child of [tree.props?.children].flat(Infinity).filter(Boolean))node.append(build(child));return node;}
        const canvas=document.createElement('canvas');canvas.width=80*scale;canvas.height=60*scale;const c=canvas.getContext('2d',{colorSpace:'srgb'});
        c.fillStyle='white';c.fillRect(0,0,80*scale,60*scale);
        for(let i=0;i<artwork.length;i++){const svg=build(artwork[i]);svg.setAttribute('width',String(Number(svg.getAttribute('width'))*scale));svg.setAttribute('height',String(Number(svg.getAttribute('height'))*scale));const image=new Image();await new Promise((resolve,reject)=>{image.onload=resolve;image.onerror=reject;image.src='data:image/svg+xml;charset=utf-8,'+encodeURIComponent(new XMLSerializer().serializeToString(svg))});c.drawImage(image,i*40*scale,0)}
        return points.map(([x,y])=>Array.from(c.getImageData(x*scale,y*scale,1,1).data));
        """#, arguments: ["artwork": trees, "accent": accent, "scale": scale, "points": points], in: nil, contentWorld: .defaultClient) as? [[Int]]
      let context = try XCTUnwrap(CGContext(data: nil, width: 80 * scale, height: 60 * scale, bitsPerComponent: 8, bytesPerRow: 320 * scale,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(.init(x: 0, y: 0, width: 80 * scale, height: 60 * scale))
      context.translateBy(x: 0, y: CGFloat(60 * scale)); context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
      NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
      AppearanceModeArtwork.draw(mode, in: .init(x: 0, y: 0, width: 80, height: 60), accent: .init(hex: accent)); NSGraphicsContext.restoreGraphicsState()
      let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
      for (index, point) in points.enumerated() {
        let offset = point[1] * scale * 320 * scale + point[0] * scale * 4
        XCTAssertEqual(pixels[offset + 3], 255)
        for channel in 0..<3 { XCTAssertEqual(Double(pixels[offset + channel]), Double(try XCTUnwrap(expected)[index][channel]), accuracy: 3, "\(mode.rawValue) \(point)") }
      }
    } } }
    XCTAssertNil(web.window)
  }

  func testOfflinePreviewUsesActualSyntaxAndPreservesSelectionAndScrollAcrossThemeUpdate() async throws {
    _ = NSApplication.shared
    let syntax = CodeSyntaxState(service: CodeSyntaxService())
    var appearance = AppearancePreferences(); appearance.theme = "light"
    let input = CodeSyntaxInput(path: AppearanceDiffPreview.path, diff: AppearanceDiffPreview.diff)
    await syntax.load(input); XCTAssertNil(syntax.error); XCTAssertEqual(syntax.language, "typescript")
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 350, height: 130), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: AppearanceCodeSurface(appearance: appearance, syntax: syntax)); window.contentView = host
    try await settle(host)
    let web = try XCTUnwrap(find(host, WKWebView.self).first); try await ready(web)
    XCTAssertFalse(web.configuration.websiteDataStore.isPersistent)
    let values = try await web.callAsyncJavaScript("return {left:document.querySelector('.pane .rows').innerText,rows:document.querySelectorAll('.row').length,lineHeight:getComputedStyle(document.querySelector('.row')).height,colors:[...document.querySelectorAll('.code span')].map(e=>e.style.color).filter(Boolean),symbols:document.body.classList.contains('symbols')}", in: nil, contentWorld: .page) as? [String: Any]
    XCTAssertEqual(values?["rows"] as? Int, 10)
    let rowHeight = try XCTUnwrap(Double((values?["lineHeight"] as? String ?? "").replacingOccurrences(of: "px", with: "")))
    XCTAssertEqual(rowHeight, 12 * 1.8, accuracy: 1 / 64)
    XCTAssertEqual(values?["symbols"] as? Bool, false); XCTAssertGreaterThan((values?["colors"] as? [String])?.count ?? 0, 10)
    _ = try await web.callAsyncJavaScript("const code=document.querySelectorAll('.pane')[0].querySelectorAll('.code')[1];const range=document.createRange();range.selectNodeContents(code);getSelection().removeAllRanges();getSelection().addRange(range);document.querySelectorAll('.pane')[0].scrollLeft=30;document.querySelectorAll('.pane')[1].scrollLeft=40;return true", in: nil, contentWorld: .page)
    let selection = try await web.callAsyncJavaScript("return getSelection().toString()", in: nil, contentWorld: .page) as? String
    XCTAssertEqual(selection, "  surface: \"sidebar\",")
    appearance.theme = "dark"; appearance.diffMarkerStyle = .symbols; appearance.dark.background = "#123456"
    host.rootView = AppearanceCodeSurface(appearance: appearance, syntax: syntax); try await settle(host)
    let changed = try await web.callAsyncJavaScript("return {selection:getSelection().toString(),scroll:[...document.querySelectorAll('.pane')].map(e=>e.scrollLeft),symbols:document.body.classList.contains('symbols'),surface:document.body.style.getPropertyValue('--surface'),marker:document.querySelector('.deletion .indicator').textContent}", in: nil, contentWorld: .page) as? [String: Any]
    XCTAssertEqual(changed?["selection"] as? String, selection); XCTAssertEqual(changed?["scroll"] as? [Int], [30, 40])
    XCTAssertEqual(changed?["symbols"] as? Bool, true); XCTAssertEqual(changed?["surface"] as? String, "#123456")
    XCTAssertEqual(changed?["marker"] as? String, "-"); XCTAssertFalse(window.isVisible)
  }

  private struct Page: View {
    @Bindable var store: WorkspaceStore
    var body: some View { AppearanceSettingsView(store: store).environment(\.appAppearance, store.appearance) }
  }
  private func makeStore() -> (WorkspaceStore, URL) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("appearance-layout-" + UUID().uuidString)
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true; store.destination = .settings
    store.settingsPage = .appearance; store.library.drafts["fixture"] = "keep draft"
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return (store, root)
  }
  private func page(_ store: WorkspaceStore) async throws -> (NSWindow, NSHostingView<Page>) {
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 816, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; let host = NSHostingView(rootView: Page(store: store)); window.contentView = host
    try await settle(host); XCTAssertFalse(window.isVisible); return (window, host)
  }
  private func find<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { find($0, type) } }
  private func settle(_ host: NSView) async throws { try await Task.sleep(for: .milliseconds(100)); host.needsLayout = true; host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
  private func key(_ code: UInt16, _ window: NSWindow) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 2, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
  }
  private func ready(_ web: WKWebView) async throws {
    for _ in 0..<100 {
      if (try? await web.callAsyncJavaScript("return document.body?.dataset.ready === 'true'", in: nil, contentWorld: .page)) as? Bool == true { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTFail("Offline preview did not finish loading")
  }
}
