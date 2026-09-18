import AppKit

extension WorkspaceStore {
  var filesVisible: Bool { destination == .workspace && showingInspector && pane == "files" }
  var filePreviewFocused: Bool {
    fileCommandsAvailable && (NSApp?.keyWindow?.firstResponder as? FilePreviewTextView)?.workspace === workspace
  }
  var fileCommandsAvailable: Bool {
    filesVisible && !restoringLibrary && presentedOverlay == nil && !showingModelPicker
      && !showingBranchPicker && shortcutCaptureCount == 0 && workspace.selectedFile != nil
  }

  func restoreOverlayFocus() {
    let target = fileFocusAfterOverlay
    fileFocusAfterOverlay = nil
    guard presentedOverlay == nil, destination == .workspace else { return }
    if let target, filesVisible, workspace.root == target.root, workspace.selectedFile == target.path {
      workspace.fileFocusRequest = UUID()
    } else {
      focusComposer = UUID()
    }
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
    if shortcuts.matches("next-task", binding) {
      workspace.moveFile(1); return true
    }
    if shortcuts.matches("previous-task", binding) {
      workspace.moveFile(-1); return true
    }
    return false
  }
}
