import AppKit
import SwiftUI
import XCTest
@testable import ShipiOS

final class SettingsNavigationTests: XCTestCase {
  @MainActor func testUnsavedChangesDialogRendersWithExplicitChoices() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 620),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: SettingsConfirmationDialog(title: "丢弃更改？",
      message: "你有未保存的更改。现在离开将丢失这些更改。",
      confirmLabel: "丢弃更改", busyLabel: "丢弃更改", busy: false,
      error: nil, width: 420, identifier: "settings-unsaved-changes-dialog",
      cancelLabel: "继续编辑", cancel: {}, confirm: {}))
    window.contentView = host
    try await Task.sleep(for: .milliseconds(150))
    host.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    if let path = ProcessInfo.processInfo.environment["SHIPIOS_SETTINGS_UNSAVED_RENDER_PATH"] {
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        .write(to: URL(fileURLWithPath: path), options: .atomic)
    }
    window.close()
  }

  @MainActor func testUnsavedModelSettingsGuardPageSearchAndExitNavigation() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.openSettings(.model)
    let resetToken = store.modelSettingsResetRequest
    store.modelSettingsDirty = true

    store.requestSettingsPage(.voice)
    XCTAssertEqual(store.settingsPage, .model)
    XCTAssertEqual(store.pendingSettingsNavigation, .page(.voice))
    store.cancelDiscardSettingsChanges()
    XCTAssertNil(store.pendingSettingsNavigation)
    XCTAssertTrue(store.modelSettingsDirty)

    let result = SettingsSearchResult(page: .shortcuts, field: .shortcutReset)
    store.revealSetting(result)
    XCTAssertEqual(store.settingsPage, .model)
    XCTAssertEqual(store.pendingSettingsNavigation, .reveal(result))
    store.confirmDiscardSettingsChanges()
    XCTAssertEqual(store.settingsPage, .shortcuts)
    XCTAssertEqual(store.settingsSearchRequest?.result, result)
    XCTAssertFalse(store.modelSettingsDirty)
    XCTAssertNotEqual(store.modelSettingsResetRequest, resetToken)

    store.requestSettingsPage(.model)
    store.modelSettingsDirty = true
    store.closeSettings()
    XCTAssertEqual(store.destination, .settings)
    XCTAssertEqual(store.pendingSettingsNavigation, .close)
    store.confirmDiscardSettingsChanges()
    XCTAssertEqual(store.destination, .workspace)
  }

  @MainActor func testUnsavedPersonalizationEditsAreDiscardedOnlyAfterConfirmation() {
    let store = WorkspaceStore(dataRoot: FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString))
    store.openSettings(.personalization)
    store.personalizationLoaded = true
    store.customInstructions = "已保存"
    store.personalizationDraft = "未保存"
    store.requestSettingsPage(.general)
    XCTAssertEqual(store.settingsPage, .personalization)
    XCTAssertEqual(store.pendingSettingsNavigation, .page(.general))
    store.cancelDiscardSettingsChanges()
    XCTAssertEqual(store.personalizationDraft, "未保存")
    store.requestSettingsPage(.general)
    store.confirmDiscardSettingsChanges()
    XCTAssertEqual(store.settingsPage, .general)
    XCTAssertEqual(store.personalizationDraft, "已保存")
  }

  @MainActor func testCommandSearchUsesEffectiveBindingsIncludingRemovedAndReassignedDefaults() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let shortcuts = ShortcutPreferences(file: root.appendingPathComponent("shortcuts.json"))
    func results(_ query: String) -> [SettingsSearchResult] {
      SettingsSearch.results(for: query, shortcutBindings: Dictionary(uniqueKeysWithValues:
        DesktopCommand.all.map { ($0.id, shortcuts.bindings($0.id)) }))
    }
    XCTAssertEqual(results("⌘N").compactMap(\.commandID), ["new"])
    try shortcuts.set(nil, for: "new")
    XCTAssertTrue(results("⌘N").isEmpty)
    try shortcuts.set(ShortcutBinding("⌘N"), for: "fork")
    XCTAssertEqual(results("⌘N").compactMap(\.commandID), ["fork"])
    XCTAssertEqual(results("快捷键 分叉").compactMap(\.commandID), ["fork"])
    XCTAssertEqual(results("创建聊天分支").compactMap(\.commandID), ["fork"])
    XCTAssertEqual(results("分叉 ⌘N").compactMap(\.commandID), ["fork"])
    XCTAssertEqual(results("分叉").first?.title, "创建聊天分支")
    XCTAssertTrue(results("分叉 ⌘B").isEmpty)
    XCTAssertTrue(results("分叉 不存在的命令").isEmpty)
    try shortcuts.set(nil, for: "fork")
    XCTAssertTrue(results("分叉 ⌘N").isEmpty)
    XCTAssertEqual(results("分叉").compactMap(\.commandID), ["fork"])
    let alternate = try XCTUnwrap(shortcuts.bindings("next-task").last)
    XCTAssertEqual(Set(results(alternate.display).compactMap(\.commandID)), ["next-task", "next-tab"])
    let allCommands = results("快捷键").filter { $0.commandID != nil }
    XCTAssertEqual(allCommands.count, DesktopCommand.all.count)
    XCTAssertEqual(Set(allCommands.map(\.id)).count, DesktopCommand.all.count)
    XCTAssertEqual(allCommands.first?.id, "shortcut:palette")
  }

  @MainActor func testCommandSearchOnlyNavigatesAndRejectsInvalidTargets() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspaceStore(dataRoot: root)
    store.library.drafts["new:none"] = "保留草稿"
    store.showProjects()
    let before = store.shortcuts.overrides
    let target = SettingsSearchResult(page: .shortcuts, commandID: "new")
    store.revealSetting(target)
    XCTAssertEqual(store.destination, .settings)
    XCTAssertEqual(store.settingsPage, .shortcuts)
    XCTAssertEqual(store.settingsSearchRequest?.result, target)
    let token = store.settingsSearchRequest?.token
    store.revealSetting(target)
    XCTAssertNotEqual(token, store.settingsSearchRequest?.token)
    for invalid in [
      SettingsSearchResult(page: .general, commandID: "new"),
      SettingsSearchResult(page: .shortcuts, field: .shortcutReset, commandID: "new"),
      SettingsSearchResult(page: .shortcuts, commandID: "unknown"),
    ] {
      store.revealSetting(invalid)
      XCTAssertEqual(store.settingsSearchRequest?.result, target)
    }
    XCTAssertEqual(store.shortcuts.overrides, before)
    XCTAssertEqual(store.shortcutCaptureCount, 0)
    XCTAssertEqual(store.library.drafts["new:none"], "保留草稿")
    store.closeSettings()
    XCTAssertEqual(store.destination, .projects)
    XCTAssertNil(store.settingsSearchRequest)
  }

  @MainActor func testSearchSelectsSubpageAndManualNavigationCancelsOldTarget() {
    let store = WorkspaceStore(dataRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let targets: [(SettingsSearchField, BrowserSettingsSection)] = [
      (.browserDownloadFolder, .downloads), (.browserDefaultAccess, .permissions),
      (.browserHistory, .history), (.browserAskDownload, .downloads),
    ]
    for (field, section) in targets {
      store.revealSetting(.init(page: .browser, field: field))
      XCTAssertEqual(store.settingsPage, .browser)
      XCTAssertEqual(store.browserSettingsSection, section)
      XCTAssertEqual(store.settingsSearchRequest?.result.field, field)
    }
    store.browserSettingsSection = .permissions
    XCTAssertNil(store.settingsSearchRequest)
    store.revealSetting(.init(page: .connections, field: .connectionThisMac))
    XCTAssertEqual(store.connectionSettingsSection, .thisMac)
    store.revealSetting(.init(page: .connections, field: .connectionSSH))
    XCTAssertEqual(store.connectionSettingsSection, .ssh)
    store.connectionSettingsSection = .devices
    XCTAssertNil(store.settingsSearchRequest)
  }

  @MainActor func testProjectControlsDisappearAndStaleResultsCannotNavigate() {
    XCTAssertFalse(SettingsSearch.results(for: "Scheme").contains { $0.field == .environmentScheme })
    XCTAssertTrue(SettingsSearch.results(for: "Scheme", hasProject: true).contains { $0.field == .environmentScheme })
    let store = WorkspaceStore(dataRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let result = SettingsSearchResult(page: .environments, field: .environmentScheme)
    store.openSettings(.general)
    store.revealSetting(result)
    XCTAssertEqual(store.settingsPage, .general)
    XCTAssertNil(store.settingsSearchRequest)
    store.project = URL(fileURLWithPath: "/first-project")
    store.revealSetting(result)
    XCTAssertEqual(store.settingsSearchRequest?.result.field, .environmentScheme)
    store.project = URL(fileURLWithPath: "/different-project")
    XCTAssertNil(store.settingsSearchRequest)
    store.project = nil
    store.revealSetting(result)
    XCTAssertNil(store.settingsSearchRequest)
  }

  func testEverySettingsPageHasTargetsAndResultsIncludeSecondaryPages() {
    XCTAssertEqual(Set(SettingsSearchField.allCases.map(\.page)), Set(SettingsNavigation.pages))
    XCTAssertEqual(SettingsSearch.results(for: "分支前缀").compactMap(\.field), [.branchPrefix])
    XCTAssertEqual(SettingsSearch.results(for: "审批策略").compactMap(\.field), [.agentApproval])
    let permissionFields = Set(SettingsSearch.results(for: "权限").compactMap(\.field))
    XCTAssertTrue(permissionFields.isSuperset(of: [
      .generalDefaultPermissions, .generalAutoReview, .generalNamedPermissions,
      .agentApprovalReviewer,
      .agentApproval, .agentSandbox, .agentFullAccess, .agentNetwork,
    ]))
    XCTAssertEqual(Set(SettingsSearch.results(for: "自动审查批准").compactMap(\.field)),
      [.generalAutoReview, .agentApprovalReviewer])
    XCTAssertEqual(SettingsSearch.results(for: "文件访问").compactMap(\.field), [.agentSandbox])
    XCTAssertTrue(SettingsSearch.results(for: "命名权限档案")
      .contains { $0.field == .generalNamedPermissions })
    XCTAssertEqual(SettingsSearch.results(for: "在输入区显示完全访问").compactMap(\.field),
      [.agentFullAccess])
    XCTAssertEqual(SettingsSearchField.agentFullAccess.page, .general)
    XCTAssertEqual(SettingsSearch.results(for: "允许网络访问").compactMap(\.field), [.agentNetwork])
    XCTAssertFalse(SettingsSearch.results(for: "允许网络访问", agentSandboxMode: .readOnly)
      .contains { $0.field == .agentNetwork })
    XCTAssertEqual(SettingsSearch.results(for: "回复详细度").compactMap(\.field), [.agentVerbosity])
    XCTAssertEqual(SettingsSearch.results(for: "推理摘要").compactMap(\.field), [.agentReasoningSummary])
    XCTAssertEqual(SettingsSearch.results(for: "搜索模式").compactMap(\.field), [.agentWebSearch])
    XCTAssertEqual(SettingsSearch.results(for: "服务支持托管网页搜索").compactMap(\.field), [.hostedWebSearch])
    XCTAssertEqual(SettingsSearch.results(for: "可用推理强度").compactMap(\.field), [.agentAvailableReasoning])
    XCTAssertEqual(SettingsSearch.results(for: "浏览器 下载位置").compactMap(\.field), [.browserDownloadFolder])
    XCTAssertEqual(SettingsSearch.results(for: "自定义指令").compactMap(\.field), [.instructions])
    XCTAssertEqual(SettingsSearch.results(for: "屏幕录制").compactMap(\.field), [.screenRecording])
    XCTAssertEqual(SettingsSearch.results(for: "用户名").compactMap(\.field), [.profileUsername])
  }

  func testSearchReturnsSpecificControlsWithStablePageOwnership() {
    XCTAssertEqual(SettingsSearch.results(for: "菜单栏").map(\.field), [.menuBar])
    XCTAssertEqual(SettingsSearch.results(for: "默认使用独立聊天").map(\.field), [.popoutScope])
    XCTAssertEqual(SettingsSearch.results(for: "弹出窗口快捷键").map(\.field), [.popoutHotkey])
    XCTAssertEqual(SettingsSearch.results(for: "外观 代码字体").map(\.field), [.lightCodeFont])
    XCTAssertEqual(SettingsSearch.results(for: "外观 界面字体").map(\.field), [.lightUIFontStyle, .lightUIFont])
    XCTAssertEqual(SettingsSearch.results(for: "api 密钥").map(\.field), [.apiKey])
    XCTAssertEqual(SettingsSearch.results(for: "base URL").map(\.field), [.apiURL])
    XCTAssertEqual(SettingsSearch.results(for: "半透明侧栏").map(\.field), [.lightPalette])
    XCTAssertTrue(SettingsSearch.results(for: "不存在的选项").isEmpty)
    XCTAssertTrue(SettingsSearch.results(for: " \n ").isEmpty)
    XCTAssertEqual(SettingsSearch.results(for: "远程").map(\.page), [.connections])
    for query in ["主题", "API", "发送", "插件"] {
      let results = SettingsSearch.results(for: query)
      XCTAssertEqual(Set(results.map(\.id)).count, results.count)
      XCTAssertTrue(results.allSatisfy { $0.field == nil || $0.field?.page == $0.page })
    }
  }

  @MainActor func testSearchNavigationPreservesDraftAndCanRevealTheSameControlAgain() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = WorkspaceStore(dataRoot: root)
    store.library.drafts["new:none"] = "待发送草稿"
    store.showProjects()
    let target = SettingsSearchResult(page: .general, field: .menuBar)
    store.revealSetting(target)
    XCTAssertEqual(store.destination, .settings)
    XCTAssertEqual(store.settingsPage, .general)
    let first = store.settingsSearchRequest
    store.revealSetting(target)
    XCTAssertNotEqual(first?.token, store.settingsSearchRequest?.token)
    XCTAssertEqual(store.settingsSearchRequest?.result, target)

    store.settingsPage = .appearance
    XCTAssertNil(store.settingsSearchRequest)
    store.revealSetting(.init(page: .appearance, field: .codeFont))
    XCTAssertEqual(store.settingsSearchRequest?.result.field, store.appearance.isDark ? .darkCodeFont : .lightCodeFont)
    store.revealSetting(.init(page: .general, field: .apiKey))
    XCTAssertEqual(store.settingsPage, .appearance, "Mismatched field routes must be rejected")
    store.closeSettings()
    XCTAssertEqual(store.destination, .projects)
    XCTAssertNil(store.settingsSearchRequest)
    XCTAssertEqual(store.library.drafts["new:none"], "待发送草稿")
  }

  func testSearchFindsControlsAndRequiresEveryQueryTerm() {
    XCTAssertEqual(SettingsNavigation.results(for: "菜单栏"), [.general])
    XCTAssertEqual(SettingsNavigation.results(for: "减少动态效果"), [.appearance])
    XCTAssertEqual(SettingsNavigation.results(for: "api 密钥"), [.model])
    XCTAssertEqual(SettingsNavigation.results(for: "  SSH\n远程 "), [.connections])
    XCTAssertTrue(SettingsNavigation.results(for: "没有这个设置").isEmpty)
    XCTAssertTrue(SettingsNavigation.results(for: "菜单栏 密钥").isEmpty)
  }

  func testNavigationKeepsEveryPageReachableWithoutDuplicates() {
    XCTAssertEqual(Set(SettingsNavigation.pages), Set(SettingsPage.allCases.map(\.navigationPage)))
    XCTAssertEqual(SettingsNavigation.pages.count, SettingsPage.allCases.count - 2)
    XCTAssertEqual(SettingsNavigation.results(for: " \n"), SettingsNavigation.pages)
  }

  func testKeyboardNavigationUsesVisibleResultsWithoutWrappingOrOpeningHiddenPages() {
    let results = SettingsNavigation.results(for: "插件")
    XCTAssertFalse(results.isEmpty)
    XCTAssertEqual(SettingsNavigation.adjacent(to: nil, offset: 1, in: results), results.first)
    XCTAssertEqual(SettingsNavigation.adjacent(to: nil, offset: -1, in: results), results.last)
    XCTAssertNil(SettingsNavigation.adjacent(to: results.first, offset: -1, in: results))
    XCTAssertNil(SettingsNavigation.adjacent(to: results.last, offset: 1, in: results))
    XCTAssertNil(SettingsNavigation.adjacent(to: nil, offset: 1, in: []))
    XCTAssertEqual(SettingsNavigation.adjacent(to: results[0], offset: 1, in: results), results[1])
  }
}
