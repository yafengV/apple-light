import AppKit

enum AppDestination: Equatable {
  case workspace, projects, plugins, skills, pluginDetail, automations, settings
}

enum PendingSettingsNavigation: Equatable {
  case page(SettingsPage)
  case reveal(SettingsSearchResult)
  case close
}

enum WorkspaceOverlay: String, Identifiable, CaseIterable {
  case commands, taskSearch, fileSearch, projectPicker, imagePreview, filePreview, worktreeCreation
  var id: String { rawValue }
  var isSearchDialog: Bool { self == .commands || self == .taskSearch || self == .fileSearch || self == .projectPicker }
  var usesWindowOverlay: Bool { self == .imagePreview || isSearchDialog }
}

extension WorkspaceStore {
  func setOverlay(_ overlay: WorkspaceOverlay, presented: Bool) {
    guard !hasSettingsConfirmation else { return }
    if presented {
      if overlay.isSearchDialog {
        if presentedOverlay?.isSearchDialog != true {
          searchDialogReturnFocus = SearchDialogReturnFocus(window: NSApp?.keyWindow, destination: destination)
        }
      } else { searchDialogReturnFocus = nil }
      if overlay.isSearchDialog, filesVisible,
        (NSApp?.keyWindow?.firstResponder as? FilePreviewTextView)?.workspace === workspace,
        let root = workspace.root, let path = workspace.selectedFile {
        fileFocusAfterOverlay = (root, path)
      } else { fileFocusAfterOverlay = nil }
      terminalFocusRequest = nil
      showingModelPicker = false
      showingBranchPicker = false
      presentedOverlay = overlay
    } else if presentedOverlay == overlay {
      presentedOverlay = nil
      if overlay == .projectPicker { projectPickerCreatesNewTask = false }
    }
  }

  private var retainedPageDestination: AppDestination {
    let page = destination == .settings ? settingsReturnDestination : destination
    guard page == .pluginDetail, let route = pluginDetailRoute else { return page }
    return route.origin == .settings ? route.settingsReturnDestination : route.origin
  }
  var retainsProjectsPage: Bool { retainedPageDestination == .projects }
  var retainsPluginsPage: Bool { retainedPageDestination == .plugins }
  var retainsSkillsPage: Bool { retainedPageDestination == .skills }
  var retainsSettingsPage: Bool {
    destination == .settings || (destination == .pluginDetail && pluginDetailRoute?.origin == .settings)
  }
  var retainsAutomationsPage: Bool { retainedPageDestination == .automations }
  var retainsStandalonePage: Bool {
    retainsProjectsPage || retainsPluginsPage || retainsSkillsPage || retainsAutomationsPage
      || destination == .pluginDetail
  }
  func openSettings(_ page: SettingsPage? = nil) {
    guard !hasSettingsConfirmation else { return }
    if destination == .settings, let page, page != settingsPage {
      requestSettingsPage(page)
      return
    }
    showingOpenSourceLicenses = false
    mcpServerEditor = nil
    pluginDetailForwardRoute = nil
    settingsSearchRequest = nil
    terminalFocusRequest = nil
    showingModelPicker = false
    showingBranchPicker = false
    if destination != .settings { settingsReturnDestination = destination }
    if let page { settingsPage = page }
    presentedOverlay = nil
    fileFocusAfterOverlay = nil
    destination = .settings
    // The hidden PTY can otherwise keep first responder and consume Escape.
    NSApp?.keyWindow?.makeFirstResponder(nil)
  }

  func closeSettings() {
    guard destination == .settings, !hasSettingsConfirmation else { return }
    if showingOpenSourceLicenses {
      showingOpenSourceLicenses = false
      return
    }
    if mcpServerEditor != nil {
      mcpServerEditor = nil
      mcpServersError = nil
      return
    }
    if hasUnsavedSettingsEdits {
      pendingSettingsNavigation = .close
      return
    }
    settingsSearchRequest = nil
    destination = settingsReturnDestination
    if destination == .workspace { focusComposer = UUID() }
  }

  var hasUnsavedSettingsEdits: Bool {
    switch settingsPage {
    case .model: modelSettingsDirty
    case .personalization: canSavePersonalizationEdits
    default: false
    }
  }

  func requestSettingsPage(_ page: SettingsPage) {
    guard !hasSettingsConfirmation, page != settingsPage else { return }
    if destination == .settings && hasUnsavedSettingsEdits {
      pendingSettingsNavigation = .page(page)
    } else {
      settingsPage = page
    }
  }

  func cancelDiscardSettingsChanges() {
    pendingSettingsNavigation = nil
  }

  func confirmDiscardSettingsChanges() {
    guard let pending = pendingSettingsNavigation else { return }
    switch settingsPage {
    case .model:
      modelSettingsDirty = false
      modelSettingsResetRequest = UUID()
    case .personalization:
      personalizationDraft = customInstructions
    default: break
    }
    pendingSettingsNavigation = nil
    switch pending {
    case .page(let page): requestSettingsPage(page)
    case .reveal(let result): revealSetting(result)
    case .close: closeSettings()
    }
  }

  @discardableResult func closeSettingsFromKeyboard(in targetWindow: NSWindow? = nil) -> Bool {
    guard destination == .settings, !hasSettingsConfirmation, presentedOverlay == nil,
      let window = targetWindow ?? NSApp?.keyWindow,
      window.attachedSheet == nil, NSApp?.modalWindow == nil,
      !SettingsPopupMenuButton.hasOpenMenu(in: window),
      shortcutCaptureCount == 0 else { return false }
    if let editor = window.firstResponder as? NSTextView,
      editor.isEditable || editor.hasMarkedText() { return false }
    closeSettings()
    return true
  }

  func showProjects() {
    closeActivity()
    pluginDetailForwardRoute = nil
    pluginDetailRoute = nil
    showingBranchPicker = false
    destination = .projects
  }

  func showPlugins() {
    closeActivity()
    pluginDetailForwardRoute = nil
    pluginDetailRoute = nil
    showingBranchPicker = false
    presentedOverlay = nil
    destination = .plugins
  }

  func showSkills() {
    closeActivity()
    pluginDetailForwardRoute = nil
    pluginDetailRoute = nil
    showingBranchPicker = false
    presentedOverlay = nil
    destination = .skills
  }

  func showAutomations(create: Bool = false) {
    closeActivity()
    pluginDetailForwardRoute = nil
    pluginDetailRoute = nil
    showingBranchPicker = false
    presentedOverlay = nil
    destination = .automations
    automationCreateRequest = create ? UUID() : nil
    automationListRequest = create ? nil : UUID()
  }

  func toggleActivity() {
    guard libraryLoaded, !hasSettingsConfirmation else { return }
    if showingActivity { closeActivity(); return }
    if destination == .settings { closeSettings() }
    showingBranchPicker = false
    showingModelPicker = false
    presentedOverlay = nil
    activityError = nil
    let entries = activityEntries
    activitySession = ActivitySession(activatedAt: Date(),
      priorityIDs: entries.filter(\.needsAttention).map(\.id),
      recentDates: Dictionary(entries.filter { !$0.needsAttention }.map { ($0.id, $0.recency) }, uniquingKeysWith: { first, _ in first }))
  }

  func closeActivity() {
    guard showingActivity else { return }
    activitySession = nil
    activityError = nil
    if destination == .workspace { focusComposer = UUID() }
  }

  func returnToWorkspace() {
    closeActivity()
    pluginDetailForwardRoute = nil
    pluginDetailRoute = nil
    destination = .workspace
    focusComposer = UUID()
  }
}
