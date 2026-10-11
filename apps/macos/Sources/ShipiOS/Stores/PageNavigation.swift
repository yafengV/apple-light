import AppKit

enum AppDestination: Equatable {
  case workspace, projects, plugins, skills, pluginDetail, automations, settings
}

enum PendingSettingsNavigation: Equatable {
  case page(SettingsPage)
  case reveal(SettingsSearchResult)
  case close
  case mcpEditorBack
}

enum WorkspaceOverlay: String, Identifiable, CaseIterable {
  case commands, taskSearch, fileSearch, projectPicker, imagePreview, filePreview, worktreeCreation
  var id: String { rawValue }
  var isSearchDialog: Bool { self == .commands || self == .taskSearch || self == .fileSearch || self == .projectPicker }
  var usesWindowOverlay: Bool { self == .imagePreview || isSearchDialog }
}

extension WorkspaceStore {
  private var mainInteractionWindow: NSWindow? {
    let windows = NSApp?.windows.filter { $0.identifier?.rawValue == "main" } ?? []
    return windows.first { $0.isKeyWindow } ?? windows.first { $0.isVisible }
      ?? windows.first ?? NSApp?.keyWindow
  }

  func setOverlay(_ overlay: WorkspaceOverlay, presented: Bool) {
    guard !hasSettingsConfirmation else { return }
    if presented {
      if overlay.isSearchDialog {
        if presentedOverlay?.isSearchDialog != true {
          searchDialogFocusRevision = UUID()
          let target = SearchDialogReturnFocus(window: mainInteractionWindow, destination: destination, store: self)
          searchDialogReturnFocus = target
          if filesVisible, (target.view as? FilePreviewTextView)?.workspace === workspace,
            let root = workspace.root, let path = workspace.selectedFile {
            fileFocusAfterOverlay = (root, path)
          } else { fileFocusAfterOverlay = nil }
        }
      } else {
        searchDialogFocusRevision = UUID()
        searchDialogReturnFocus = nil
        fileFocusAfterOverlay = nil
      }
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
    if destination == .settings {
      if let page, page != settingsPage { requestSettingsPage(page) }
      return
    }
    showingOpenSourceLicenses = false
    mcpServerEditor = nil
    pluginDetailForwardRoute = nil
    settingsSearchRequest = nil
    terminalFocusRequest = nil
    showingModelPicker = false
    showingBranchPicker = false
    // AppKit can retain an older window with the same scene identifier after
    // closing. Capture the active main window before falling back to a visible
    // or hidden scene; array order is not an ownership signal.
    let window = mainInteractionWindow
    if destination != .settings {
      settingsReturnDestination = destination
      settingsFocusRevision = UUID()
      let origin = presentedOverlay?.isSearchDialog == true
        && searchDialogReturnFocus?.window === window ? searchDialogReturnFocus : nil
      settingsReturnFocus = SettingsReturnFocus(target: origin
        ?? SearchDialogReturnFocus(window: window, destination: destination), store: self)
    }
    searchDialogFocusRevision = UUID()
    searchDialogReturnFocus = nil
    if let page { settingsPage = page }
    presentedOverlay = nil
    fileFocusAfterOverlay = nil
    destination = .settings
    // The hidden PTY can otherwise keep first responder and consume Escape.
    window?.makeFirstResponder(nil)
  }

  func closeSettings(onCancelFocus: (() -> Void)? = nil) {
    guard destination == .settings, !hasSettingsConfirmation else { return }
    if showingOpenSourceLicenses {
      showingOpenSourceLicenses = false
      return
    }
    if mcpServerEditor != nil {
      if hasUnsavedMCPServerEdits {
        beginSettingsNavigationConfirmation(.mcpEditorBack, onCancelFocus: onCancelFocus)
        return
      }
      mcpServerEditor = nil
      mcpServersError = nil
      return
    }
    if hasUnsavedSettingsEdits {
      beginSettingsNavigationConfirmation(.close, onCancelFocus: onCancelFocus)
      return
    }
    settingsSearchRequest = nil
    let returnFocus = settingsReturnFocus
    settingsReturnFocus = nil
    destination = settingsReturnDestination
    // Complete the retained page's enabling update before AppKit dispatches
    // the next queued key. Otherwise it still targets the settings field editor.
    (returnFocus?.target.window ?? mainInteractionWindow)?.contentView?.layoutSubtreeIfNeeded()
    if returnFocus?.restore(store: self) != true, destination == .workspace {
      focusComposer = UUID()
    }
  }

  var hasUnsavedSettingsEdits: Bool {
    if hasUnsavedMCPServerEdits { return true }
    return switch settingsPage {
    case .model: modelSettingsDirty
    case .personalization: canSavePersonalizationEdits
    default: false
    }
  }

  func requestSettingsPage(_ page: SettingsPage, onCancelFocus: (() -> Void)? = nil,
    onConfirmFocus: (() -> Void)? = nil) {
    guard !hasSettingsConfirmation, page != settingsPage else { return }
    if destination == .settings && hasUnsavedSettingsEdits {
      beginSettingsNavigationConfirmation(.page(page), onCancelFocus: onCancelFocus,
        onConfirmFocus: onConfirmFocus ?? { [weak self] in self?.settingsSearchFocusRequest = UUID() })
    } else {
      settingsPage = page
    }
  }

  func cancelDiscardSettingsChanges() {
    guard pendingSettingsNavigation != nil else { return }
    let returnFocus = settingsDiscardReturnFocus
    settingsDiscardReturnFocus = nil
    pendingSettingsNavigation = nil
    returnFocus?.restore(store: self)
  }

  func beginSettingsNavigationConfirmation(_ pending: PendingSettingsNavigation,
    onCancelFocus: (() -> Void)? = nil, onConfirmFocus: (() -> Void)? = nil) {
    guard destination == .settings, !hasSettingsConfirmation else { return }
    settingsDiscardFocusRevision = UUID()
    settingsDiscardReturnFocus = SettingsDiscardReturnFocus(window: mainInteractionWindow,
      store: self, restoreControl: onCancelFocus, confirmControl: onConfirmFocus)
    pendingSettingsNavigation = pending
  }

  func confirmDiscardSettingsChanges() {
    guard let pending = pendingSettingsNavigation else { return }
    let returnFocus = settingsDiscardReturnFocus
    settingsDiscardFocusRevision = UUID()
    settingsDiscardReturnFocus = nil
    if mcpServerEditor != nil { mcpServerEditor = nil; mcpServersError = nil }
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
    case .page(let page):
      requestSettingsPage(page)
      returnFocus?.restore(store: self, afterNavigation: true)
    case .reveal(let result):
      revealSetting(result)
      returnFocus?.restore(store: self, afterNavigation: true)
    case .close: closeSettings()
    case .mcpEditorBack: settingsSearchFocusRequest = UUID()
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
    worktreeForkPresentation.dismiss()
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
