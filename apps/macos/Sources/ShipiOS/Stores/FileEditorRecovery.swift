import Foundation

extension WorkspaceStore {
  func bindFileEditorRecovery(to workspace: DeveloperWorkspace) {
    workspace.recoveredFileDrafts = library.fileEditorRecovery
    workspace.onFileEditResolved = { [weak self] key in
      guard let self, self.library.fileEditorRecovery[key] != nil else { return }
      var candidate = self.library
      candidate.fileEditorRecovery[key] = nil
      do { try self.commitLibrary(candidate) }
      catch { self.error = "无法更新文件草稿记录：\(error.localizedDescription)" }
    }
  }

  func captureFileEditorRecovery(from workspace: DeveloperWorkspace) {
    guard libraryLoaded else { return }
    var candidate = library
    for (key, session) in workspace.fileEditorSessions where session.hasUnsavedChanges {
      let draft = FileEditorRecoveryDraft(baseText: session.baseText, text: session.text)
      candidate.fileEditorRecovery[key] = draft
    }
    guard candidate.fileEditorRecovery != library.fileEditorRecovery else { return }
    do { try commitLibrary(candidate) }
    catch { self.error = "无法保存文件草稿：\(error.localizedDescription)" }
  }
}
