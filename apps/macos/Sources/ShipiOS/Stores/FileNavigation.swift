import AppKit

extension WorkspaceStore {
  var filesVisible: Bool {
    destination == .workspace && showsWorkspaceInspector && pane == "files"
      && presentedWorkspaceContentTabs(in: .right).isEmpty
  }
  var commandFileWorkspace: DeveloperWorkspace? {
    guard destination == .workspace else { return nil }
    if filesVisible, filePreviewFocused || workspace.fileFind.isPresented { return workspace }
    guard let tab = focusedWorkspaceContentTab ?? activeWorkspaceContentTab, case .file = tab,
      workspaceTabPlacement(tab.id) != .detached else { return nil }
    return fileTabWorkspaces[tab.id]
  }
  var filePreviewFocused: Bool {
    fileCommandsAvailable && (NSApp?.keyWindow?.firstResponder as? FilePreviewTextView)?.workspace === workspace
  }
  var fileCommandsAvailable: Bool {
    filesVisible && !restoringLibrary && presentedOverlay == nil && !showingModelPicker
      && !showingBranchPicker && shortcutCaptureCount == 0 && workspace.selectedFile != nil
  }

  func restoreOverlayFocus() {
    let returnFocus = searchDialogReturnFocus
    searchDialogReturnFocus = nil
    let target = fileFocusAfterOverlay
    fileFocusAfterOverlay = nil
    guard presentedOverlay == nil else { return }
    guard destination == .workspace else { returnFocus?.restore(store: self); return }
    if let returnFocus, returnFocus.hadSourceView || returnFocus.isFileSource {
      if returnFocus.isFileSource { _ = returnFocus.restoreFileFocus(store: self) }
      else { returnFocus.restore(store: self) }
      // An obsolete source must not redirect focus to the parent composer.
      return
    }
    if let target, filesVisible, workspace.root == target.root, workspace.selectedFile == target.path {
      workspace.fileFocusRequest = UUID()
    } else {
      focusComposer = UUID()
    }
  }

  func cancelFileSearch() {
    guard presentedOverlay == .fileSearch else { return }
    setOverlay(.fileSearch, presented: false)
    restoreOverlayFocus()
  }

  @discardableResult func openFileSearchResult(_ path: String) -> Bool {
    guard presentedOverlay == .fileSearch, destination == .workspace,
      !libraryRecoveryBlocksInteraction, openFileTab(path),
      let tab = focusedWorkspaceContentTab, case .file = tab else { return false }
    // Selection hands focus to the result, whereas cancellation returns to the
    // source. Reopening an existing tab also needs a fresh editor focus request.
    searchDialogFocusRevision = UUID()
    searchDialogReturnFocus = nil
    fileFocusAfterOverlay = nil
    setOverlay(.fileSearch, presented: false)
    fileTabWorkspace(tab).fileFocusRequest = UUID()
    return true
  }

  func closeFileTab(_ path: String) {
    let wasSelected = workspace.selectedFile == path
    workspace.closeFile(path)
    if wasSelected, filesVisible, workspace.selectedFile == nil { focusComposer = UUID() }
  }

  /// Called only while the native source preview is first responder.
  func handleFileShortcut(_ binding: ShortcutBinding) -> Bool {
    guard fileCommandsAvailable else { return false }
    if binding == ShortcutBinding("⌘W"), let path = workspace.selectedFile {
      closeFileTab(path); return true
    }
    if shortcuts.matches("browser-address", binding) {
      if !workspace.fileLoading, workspace.fileError == nil { workspace.showingFileLine = true }
      return true
    }
    if shortcuts.matches("next-tab", binding) {
      workspace.moveFile(1); return true
    }
    if shortcuts.matches("previous-tab", binding) {
      workspace.moveFile(-1); return true
    }
    return false
  }
}
