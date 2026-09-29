import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import ShipiOS

@MainActor final class AppearanceThemeImportTests: XCTestCase {
  func testActualDialogInputCallbacksAndNoFormSubmit() throws {
    let f = try fixture()
    XCTAssertEqual(f["settingsSHA256"] as? String, "3a2ff568faaa71fa98cde8ca59a04d525baf13ce81a470ea8ae72c5283800753")
    XCTAssertEqual(f["initialSHA256"] as? String, "01c04b2e5a96e5dd4c97e02ffa183f571a55bef7a221abd99404246c430f2212")
    XCTAssertEqual(f["modalWidthClass"] as? String, "w-[520px]")
    XCTAssertEqual(f["closeHandlerPreventsDefaultWithoutTrigger"] as? Bool, true)
    let cases = try XCTUnwrap(f["cases"] as? [[String: Any]]); XCTAssertEqual(cases.count, 8)
    for sample in cases {
      let tree = try dict(sample["tree"]), root = try dict(tree["props"])
      XCTAssertEqual(root["size"] as? String, "default")
      let body = try dict(root["children"]), bodyProps = try dict(body["props"])
      let sections = try XCTUnwrap(bodyProps["children"] as? [[String: Any]])
      XCTAssertEqual(sections.count, 3)
      let input = try dict(try dict(sections[1]["props"])["children"]), props = try dict(input["props"])
      XCTAssertEqual(input["type"] as? String, "Input"); XCTAssertEqual(props["type"] as? String, "text")
      XCTAssertEqual(props["autoFocus"] as? Bool, true); XCTAssertEqual(props["spellCheck"] as? Bool, false)
      XCTAssertEqual(props["value"] as? String, "draft"); XCTAssertEqual(props["placeholder"] as? String, "example")
      XCTAssertEqual(props["aria-label"] as? String, (sample["variant"] as! String) + " 主题分享字符串")
      let keys = try XCTUnwrap(sample["inputKeys"] as? [String])
      XCTAssertFalse(keys.contains("onKeyDown")); XCTAssertFalse(keys.contains("onSubmit"))
      let callbacks = try dict(sample["callbacks"])
      XCTAssertEqual(callbacks["changes"] as? [String], ["changed"]); XCTAssertEqual(callbacks["closed"] as? Int, 1)
      let footer = try dict(try dict(sections[2]["props"])["children"])
      let actions = try XCTUnwrap(try dict(footer["props"])["children"] as? [[String: Any]])
      XCTAssertEqual(try dict(actions[1]["props"])["disabled"] as? Bool, !(sample["valid"] as! Bool))
    }
  }
  func testActualCSSDialogGeometryInOfflineDocument() async throws {
    let f = try fixture(), c = WKWebViewConfiguration(); c.websiteDataStore = .nonPersistent()
    let web = WKWebView(frame: .zero, configuration: c)
    let result = try await web.callAsyncJavaScript(#"""
      document.documentElement.dataset.codexWindowType='electron';
      const style=document.createElement('style');style.textContent=css;document.head.append(style);
      const body=document.createElement('div');body.className=bodyClass;body.style.width='520px';
      const section=()=>{const e=document.createElement('div');e.className=sectionClass;body.append(e);return e};
      const title=document.createElement('div');title.className=headingClass;title.textContent='导入主题';section().append(title);
      const input=document.createElement('input');input.type='text';input.className=inputClass;section().append(input);
      const footer=document.createElement('div');footer.className='flex w-auto items-center justify-end gap-2';
      const buttons=[ghost,primary].map(classes=>{const e=document.createElement('button');e.className=classes;e.textContent='导入主题';footer.append(e);return e});section().append(footer);
      document.body.append(body);const r=e=>e.getBoundingClientRect();const s=getComputedStyle(input);
      return {height:r(body).height,inputHeight:r(input).height,inputWidth:r(input).width,fontSize:s.fontSize,radius:s.borderRadius,padding:s.paddingLeft,
        headingHeight:r(title).height,buttonHeight:r(buttons[0]).height,sectionGap:r(input).top-r(title).bottom,footerGap:r(footer).top-r(input).bottom};
      """#, arguments: ["css": f["css"]!, "bodyClass": try dict(try dict(f["body"])["props"])["className"]!,
        "sectionClass": try dict(try dict(f["section"])["props"])["className"]!,
        "headingClass": "heading-dialog min-w-0 font-semibold", "inputClass": f["inputClasses"]!,
        "ghost": try dict(try dict(f["buttonGhost"])["props"])["className"]!,
        "primary": try dict(try dict(f["buttonPrimary"])["props"])["className"]!], in: nil, contentWorld: .defaultClient) as? [String: Any]
    XCTAssertEqual(result?["height"] as? Double, 156); XCTAssertEqual(result?["inputHeight"] as? Double, 36)
    XCTAssertEqual(result?["inputWidth"] as? Double, 480); XCTAssertEqual(result?["buttonHeight"] as? Double, 28)
    XCTAssertEqual(result?["headingHeight"] as? Double, 28); XCTAssertEqual(result?["sectionGap"] as? Double, 12)
    XCTAssertEqual(result?["footerGap"] as? Double, 12); XCTAssertEqual(result?["fontSize"] as? String, "13px")
    XCTAssertEqual(result?["padding"] as? String, "10px"); XCTAssertEqual(result?["radius"] as? String, "8px")
    XCTAssertNil(web.window)
  }
  func testHiddenNativeDialogSingleLinePlaceholderAndFocusTrap() async throws {
    let (store, _) = makeStore(); store.beginAppearanceImport(dark: false)
    let session = try XCTUnwrap(store.appearanceThemeImport)
    let (window, host, view) = try await modal(store); defer { window.close() }
    let owner = try XCTUnwrap(view.owner)
    XCTAssertTrue(view.field.currentEditor() === window.firstResponder)
    XCTAssertEqual(view.field.stringValue, ""); XCTAssertEqual(view.field.accessibilityLabel(), "浅色 主题分享字符串")
    XCTAssertEqual(view.field.placeholderAttributedString?.string, try store.appearance.themeShare(dark: false).encoded())
    XCTAssertTrue(view.field.usesSingleLineMode); XCTAssertTrue(view.field.cell?.isScrollable == true)
    XCTAssertEqual(view.dialogFrame.size, .init(width: 520, height: 156)); XCTAssertEqual(view.submit.frame.height, 28)
    XCTAssertFalse(view.submit.isEnabled); XCTAssertNil(window.attachedSheet)
    XCTAssertEqual(view.accessibilitySubrole(), .dialog); XCTAssertTrue(view.isAccessibilityModal())
    XCTAssertEqual(view.accessibilityFrame().size, view.dialogFrame.size)
    XCTAssertTrue(owner.handle(try key(48, window), in: view)); XCTAssertTrue(window.firstResponder === view.cancel)
    XCTAssertTrue(owner.handle(try key(48, window), in: view)); XCTAssertTrue(window.firstResponder === view.close)
    XCTAssertTrue(owner.handle(try key(48, window), in: view)); XCTAssertTrue(view.field.currentEditor() === window.firstResponder)
    XCTAssertTrue(owner.handle(try key(48, window, flags: .shift), in: view)); XCTAssertTrue(window.firstResponder === view.close)
    session.value = try changedTheme(store, dark: false); try await settle(host)
    XCTAssertTrue(view.submit.isEnabled)
    window.makeFirstResponder(view.cancel)
    XCTAssertTrue(owner.handle(try key(48, window), in: view)); XCTAssertTrue(window.firstResponder === view.submit)
    window.makeFirstResponder(view.field)
    XCTAssertTrue(owner.handle(try key(36, window), in: view)); XCTAssertTrue(store.appearanceThemeImport === session)
    XCTAssertFalse(owner.handle(try key(49, window), in: view), "Space is input, not a submit shortcut")
    XCTAssertEqual(store.library.drafts["fixture"], "keep draft"); XCTAssertFalse(window.isVisible)
  }
  func testImportFailureKeepsFieldSelectionDraftAndRetryOnlyChangesChosenVariant() async throws {
    let (store, root) = makeStore(); store.beginAppearanceImport(dark: false)
    let session = try XCTUnwrap(store.appearanceThemeImport); session.value = try changedTheme(store, dark: false)
    let (window, host, view) = try await modal(store); defer { window.close() }
    let editor = try XCTUnwrap(view.field.currentEditor() as? NSTextView); editor.selectedRange = .init(location: 5, length: 8)
    let original = store.appearance, input = session.value
    try FileManager.default.createDirectory(at: root.appendingPathComponent("workspace.json"), withIntermediateDirectories: true)
    XCTAssertFalse(store.submitAppearanceImport(session)); try await settle(host)
    XCTAssertTrue(store.appearanceThemeImport === session); XCTAssertEqual(session.value, input)
    XCTAssertEqual(store.appearance, original); XCTAssertEqual(editor.selectedRange, .init(location: 5, length: 8))
    XCTAssertTrue(window.firstResponder === editor); XCTAssertNil(store.generalSettingsError)
    XCTAssertEqual(store.notices.items.first?.title, "无法导入 浅色 主题")
    XCTAssertEqual(store.notices.items.first?.level, .error)
    try FileManager.default.removeItem(at: root.appendingPathComponent("workspace.json"))
    XCTAssertTrue(view.submit.accessibilityPerformPress()); try await settle(host)
    XCTAssertNil(store.appearanceThemeImport); XCTAssertEqual(session.value, "")
    XCTAssertEqual(store.appearance.light.background, "#234567"); XCTAssertEqual(store.appearance.dark, original.dark)
    XCTAssertEqual(try WorkspaceLibrary.load(from: root.appendingPathComponent("workspace.json")).appearance, store.appearance)
    XCTAssertEqual(store.notices.items.first?.title, "已导入 浅色 主题"); XCTAssertEqual(store.library.drafts["fixture"], "keep draft")
    XCTAssertFalse(window.isVisible)
  }
  func testMarkedTextAndUndoRemainNativeAndDoNotSubmitOrClose() async throws {
    let (store, _) = makeStore(); store.beginAppearanceImport(dark: false)
    let (window, host, view) = try await modal(store); defer { window.close() }
    let owner = try XCTUnwrap(view.owner), editor = try XCTUnwrap(view.field.currentEditor() as? NSTextView)
    editor.insertText("draft", replacementRange: .init(location: 0, length: 0))
    owner.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: view.field))
    XCTAssertEqual(store.appearanceThemeImport?.value, "draft")
    let undo = try XCTUnwrap(editor.undoManager); XCTAssertTrue(undo.canUndo)
    undo.undo(); XCTAssertEqual(editor.string, "")
    undo.redo(); XCTAssertEqual(editor.string, "draft")
    editor.setMarkedText("中文", selectedRange: .init(location: 2, length: 0), replacementRange: .init(location: 5, length: 0))
    XCTAssertFalse(owner.handle(try key(53, window), in: view)); XCTAssertFalse(owner.handle(try key(36, window), in: view))
    XCTAssertNotNil(store.appearanceThemeImport); editor.unmarkText()
    XCTAssertFalse(editor.isContinuousSpellCheckingEnabled); XCTAssertFalse(editor.isAutomaticQuoteSubstitutionEnabled)
    XCTAssertTrue(owner.control(view.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    XCTAssertNotNil(store.appearanceThemeImport)
    try await settle(host); XCTAssertFalse(window.isVisible)
  }
  func testDismissClearsDraftDoesNotReturnToTriggerAndReopenStartsEmpty() async throws {
    let (store, _) = makeStore(); let source = AppearanceActionButton.Control()
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let content = NSView(frame: .init(x: 0, y: 0, width: 800, height: 500)); window.contentView = content
    source.frame = .init(x: 0, y: 0, width: 100, height: 28); content.addSubview(source); window.makeFirstResponder(source)
    store.beginAppearanceImport(dark: true, source: source); let session = try XCTUnwrap(store.appearanceThemeImport)
    session.value = "discard this"
    let host = NSHostingView(rootView: Probe(store: store)); host.frame = content.bounds; content.addSubview(host)
    try await settle(host); let view = try XCTUnwrap(find(host, AppearanceThemeImportView.Surface.self).first), owner = try XCTUnwrap(view.owner)
    XCTAssertTrue(owner.handle(try key(53, window), in: view)); try await settle(host)
    XCTAssertEqual(session.value, ""); XCTAssertNil(store.appearanceThemeImport); XCTAssertFalse(window.firstResponder === source)
    store.beginAppearanceImport(dark: true, source: source); try await settle(host)
    let current = try XCTUnwrap(store.appearanceThemeImport); XCTAssertNotEqual(current.id, session.id); XCTAssertEqual(current.value, "")
    owner.dismiss(view); XCTAssertTrue(store.appearanceThemeImport === current, "Unmounted modal cannot dismiss its successor")
    let next = try XCTUnwrap(find(host, AppearanceThemeImportView.Surface.self).first)
    XCTAssertFalse(try XCTUnwrap(next.owner).handle(try key(13, window, flags: .command, characters: "w"), in: next))
    XCTAssertTrue(next.close.accessibilityPerformPress())
    XCTAssertNil(store.appearanceThemeImport); XCTAssertFalse(window.isVisible)
  }
  func testFreshGuardsRejectRestoringHiddenVariantAndStalePageCallbacks() async throws {
    let (store, _) = makeStore(); store.appearance.theme = "light"
    store.beginAppearanceImport(dark: true); XCTAssertNil(store.appearanceThemeImport)
    store.beginAppearanceImport(dark: false); let session = try XCTUnwrap(store.appearanceThemeImport)
    session.value = try changedTheme(store, dark: false)
    let (window, host, view) = try await modal(store); defer { window.close() }
    let owner = try XCTUnwrap(view.owner), original = store.appearance
    store.restoringLibrary = true; XCTAssertFalse(store.submitAppearanceImport(session)); try await settle(host)
    XCTAssertFalse(view.field.isEnabled); XCTAssertFalse(view.submit.isEnabled)
    store.restoringLibrary = false; try await settle(host)
    XCTAssertTrue(view.submit.isEnabled)
    store.settingsPage = .general; XCTAssertNil(store.appearanceThemeImport); XCTAssertEqual(session.value, "")
    XCTAssertFalse(store.submitAppearanceImport(session)); owner.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: view.field))
    XCTAssertEqual(store.appearance, original)
    store.settingsPage = .appearance; store.beginAppearanceImport(dark: false)
    let hidden = try XCTUnwrap(store.appearanceThemeImport); hidden.value = "hidden variant"
    store.appearance.theme = "dark"; XCTAssertNil(store.appearanceThemeImport); XCTAssertEqual(hidden.value, "")
    store.beginAppearanceImport(dark: true)
    store.destination = .workspace; XCTAssertNil(store.appearanceThemeImport); XCTAssertFalse(window.isVisible)
  }
  func testOutsideClickClosesAndInsideClickDoesNotFallThrough() async throws {
    let (store, _) = makeStore(); store.beginAppearanceImport(dark: false)
    let session = try XCTUnwrap(store.appearanceThemeImport); session.value = "partial"
    let (window, _, view) = try await modal(store); defer { window.close() }
    func click(_ point: NSPoint) throws -> NSEvent {
      try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 2,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
    view.mouseDown(with: try click(.init(x: view.dialogFrame.midX, y: view.dialogFrame.minY + 52)))
    XCTAssertTrue(store.appearanceThemeImport === session)
    view.mouseDown(with: try click(.init(x: 8, y: 8)))
    XCTAssertNil(store.appearanceThemeImport); XCTAssertEqual(session.value, "")
    XCTAssertEqual(store.destination, .settings); XCTAssertFalse(window.isVisible)
  }
  func testTwoWindowsKeepDraftsKeyboardAndLateHandlersIndependent() async throws {
    let (first, _) = makeStore(), (second, _) = makeStore()
    first.beginAppearanceImport(dark: false); second.beginAppearanceImport(dark: true)
    let a = try XCTUnwrap(first.appearanceThemeImport), b = try XCTUnwrap(second.appearanceThemeImport)
    a.value = "first draft"; b.value = "second draft"
    let (w1, _, v1) = try await modal(first), (w2, _, v2) = try await modal(second)
    defer { w1.close(); w2.close() }
    XCTAssertTrue(try XCTUnwrap(v1.owner).handle(try key(53, w1), in: v1))
    XCTAssertNil(first.appearanceThemeImport); XCTAssertTrue(second.appearanceThemeImport === b); XCTAssertEqual(b.value, "second draft")
    XCTAssertTrue(v2.field.currentEditor() === w2.firstResponder)
    XCTAssertFalse(w1.isVisible); XCTAssertFalse(w2.isVisible)
  }
  func testLiveFontsUseUIScaleAndKeepEditorSelectionAndThemePlaceholder() async throws {
    let (store, _) = makeStore(); var preferences = store.appearance; preferences.theme = "light"
    preferences.light.codeFont = "Menlo"; XCTAssertTrue(store.commitAppearance(preferences))
    store.beginAppearanceImport(dark: false); let session = try XCTUnwrap(store.appearanceThemeImport); session.value = "partial draft"
    let (window, host, view) = try await modal(store); defer { window.close() }
    let editor = try XCTUnwrap(view.field.currentEditor() as? NSTextView); editor.selectedRange = .init(location: 3, length: 4)
    XCTAssertEqual(view.field.font?.pointSize, 13); XCTAssertEqual(view.field.font?.familyName, "Menlo")
    preferences.uiSize = 16; preferences.codeSize = 24; preferences.light.uiFont = "Helvetica"
    XCTAssertTrue(store.commitAppearance(preferences)); try await settle(host)
    XCTAssertTrue(find(host, AppearanceThemeImportView.Surface.self).first === view)
    XCTAssertTrue(view.field.currentEditor() === editor); XCTAssertEqual(editor.selectedRange, .init(location: 3, length: 4))
    XCTAssertEqual(view.field.stringValue, "partial draft"); XCTAssertEqual(session.value, "partial draft")
    XCTAssertEqual(view.field.font?.pointSize, 15); XCTAssertEqual(view.field.font?.familyName, "Menlo")
    XCTAssertEqual(view.label.font?.pointSize, 23); XCTAssertEqual(view.label.font?.familyName, "Helvetica")
    XCTAssertEqual(view.field.placeholderAttributedString?.string, try store.appearance.themeShare(dark: false).encoded())
    XCTAssertFalse(window.isVisible)
  }
  func testMainRootOwnsModalBlocksBackgroundNavigationAndUsesTextHeaderButtons() async throws {
    let (store, _) = makeStore()
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; defer { window.close() }
    let host = NSHostingView(rootView: MainProbe(store: store)); window.contentView = host; try await settle(host)
    let action = try XCTUnwrap(find(host, AppearanceActionButton.Control.self).first { $0.accessibilityLabel() == "导入浅色主题" })
    XCTAssertEqual(action.title, "导入"); XCTAssertEqual(action.frame.height, 28)
    XCTAssertTrue(action.accessibilityPerformPress()); try await settle(host)
    let session = try XCTUnwrap(store.appearanceThemeImport), view = try XCTUnwrap(find(host, AppearanceThemeImportView.Surface.self).first)
    XCTAssertEqual(view.bounds.width, host.bounds.width, accuracy: 1); XCTAssertEqual(view.bounds.height, host.bounds.height, accuracy: 1)
    XCTAssertNil(window.attachedSheet); XCTAssertFalse(store.paletteCommandEnabled("commands")); XCTAssertFalse(store.paletteCommandEnabled("back"))
    store.closeSettings(); store.openSettings(.general); store.revealSetting(.init(page: .general, field: nil)); store.setOverlay(.commands, presented: true)
    XCTAssertEqual(store.destination, .settings); XCTAssertEqual(store.settingsPage, .appearance); XCTAssertNil(store.presentedOverlay)
    XCTAssertTrue(view.close.accessibilityPerformPress()); try await settle(host)
    XCTAssertNil(store.appearanceThemeImport); XCTAssertEqual(session.value, ""); XCTAssertEqual(store.destination, .settings)
    XCTAssertEqual(store.library.drafts["fixture"], "keep draft"); XCTAssertFalse(window.isVisible)
  }
  private struct Probe: View {
    @Bindable var store: WorkspaceStore
    var body: some View {
      ZStack { if let session = store.appearanceThemeImport { AppearanceThemeImportView(store: store, session: session).id(session.id) } }
        .environment(\.appAppearance, store.appearance)
    }
  }
  private struct MainProbe: View {
    @Bindable var store: WorkspaceStore
    var body: some View { AppContentView(store: store).environment(\.appAppearance, store.appearance) }
  }
  private func makeStore() -> (WorkspaceStore, URL) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("theme-import-" + UUID().uuidString)
    let store = WorkspaceStore(dataRoot: root); store.libraryLoaded = true; store.destination = .settings; store.settingsPage = .appearance
    store.library.drafts["fixture"] = "keep draft"
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return (store, root)
  }
  private func modal(_ store: WorkspaceStore) async throws -> (NSWindow, NSHostingView<Probe>, AppearanceThemeImportView.Surface) {
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; let host = NSHostingView(rootView: Probe(store: store)); window.contentView = host
    try await settle(host); return (window, host, try XCTUnwrap(find(host, AppearanceThemeImportView.Surface.self).first))
  }
  private func changedTheme(_ store: WorkspaceStore, dark: Bool) throws -> String {
    var next = store.appearance; if dark { next.dark.background = "#234567" } else { next.light.background = "#234567" }
    return try next.themeShare(dark: dark).encoded()
  }
  private func fixture() throws -> [String: Any] {
    try dict(JSONSerialization.jsonObject(with: Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "appearance_import_reference", withExtension: "json", subdirectory: "Fixtures")))))
  }
  private func dict(_ value: Any?) throws -> [String: Any] { try XCTUnwrap(value as? [String: Any]) }
  private func find<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { find($0, type) } }
  private func settle(_ host: NSView) async throws { try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(60)) }
  private func key(_ code: UInt16, _ window: NSWindow, flags: NSEvent.ModifierFlags = [], characters: String = "") throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 2, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
  }
}
