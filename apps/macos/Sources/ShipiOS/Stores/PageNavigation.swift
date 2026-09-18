import AppKit

enum AppDestination: Equatable {
  case workspace, projects, plugins, pluginDetail, automations, settings
}

enum WorkspaceOverlay: String, Identifiable, CaseIterable {
  case commands, taskSearch, fileSearch, imagePreview, filePreview, worktreeCreation
  var id: String { rawValue }
  var isSearchDialog: Bool { self == .commands || self == .taskSearch || self == .fileSearch }
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
    }
  }

  private var retainedPageDestination: AppDestination {
    let page = destination == .settings ? settingsReturnDestination : destination
    guard page == .pluginDetail, let route = pluginDetailRoute else { return page }
    return route.origin == .settings ? route.settingsReturnDestination : route.origin
  }
  var retainsProjectsPage: Bool { retainedPageDestination == .projects }
  var retainsPluginsPage: Bool { retainedPageDestination == .plugins }
  var retainsSettingsPage: Bool {
    destination == .settings || (destination == .pluginDetail && pluginDetailRoute?.origin == .settings)
  }
  var retainsAutomationsPage: Bool { retainedPageDestination == .automations }
  var retainsStandalonePage: Bool {
    retainsProjectsPage || retainsPluginsPage || retainsAutomationsPage || destination == .pluginDetail
  }
  func openSettings(_ page: SettingsPage? = nil) {
    guard !hasSettingsConfirmation else { return }
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
    if mcpServerEditor != nil {
      mcpServerEditor = nil
      mcpServersError = nil
      return
    }
    settingsSearchRequest = nil
    destination = settingsReturnDestination
    if destination == .workspace { focusComposer = UUID() }
  }

  @discardableResult func closeSettingsFromKeyboard(in targetWindow: NSWindow? = nil) -> Bool {
    guard destination == .settings, !hasSettingsConfirmation, presentedOverlay == nil,
      let window = targetWindow ?? NSApp?.keyWindow,
      window.attachedSheet == nil, NSApp?.modalWindow == nil,
      shortcutCaptureCount == 0 else { return false }
    if let editor = window.firstResponder as? NSTextView,
      editor.isEditable || editor.hasMarkedText() { return false }
    closeSettings()
    return true
  }

  func showProjects() {
    pluginDetailForwardRoute = nil
    pluginDetailRoute = nil
    showingBranchPicker = false
    destination = .projects
  }

  func showPlugins() {
    pluginDetailForwardRoute = nil
    pluginDetailRoute = nil
    showingBranchPicker = false
    presentedOverlay = nil
    destination = .plugins
  }

  func showAutomations() {
    pluginDetailForwardRoute = nil
    pluginDetailRoute = nil
    showingBranchPicker = false
    presentedOverlay = nil
    destination = .automations
  }

  func returnToWorkspace() {
    pluginDetailForwardRoute = nil
    pluginDetailRoute = nil
    destination = .workspace
    focusComposer = UUID()
  }
}
