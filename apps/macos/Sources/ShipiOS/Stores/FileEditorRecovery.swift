import Foundation

extension WorkspaceStore {
  func bindFileEditorRecovery(to workspace: DeveloperWorkspace,
    context: FileEditorRecoveryContext = .init(kind: .mainTree)) {
    if let previous = workspace.fileEditorRecoveryContext, previous != context {
      workspace.previousFileEditorRecoveryContexts.insert(previous)
    }
    workspace.fileEditorRecoveryContext = context
    refreshFileEditorRecovery(in: workspace)
    workspace.onFileEditResolved = { [weak self, weak workspace] key in
      guard let self, let workspace, let selection = workspace.fileEditorRecoverySelections[key] else { return }
      var candidate = self.library
      candidate.fileEditorRecovery[key] = candidate.fileEditorRecovery[key]?.removing(selection)
      do {
        if candidate.fileEditorRecovery != self.library.fileEditorRecovery { try self.commitLibrary(candidate) }
        workspace.fileEditorRecoverySelections[key] = nil
      }
      catch { self.error = "无法更新文件草稿记录：\(error.localizedDescription)" }
    }
  }

  private func refreshFileEditorRecovery(in workspace: DeveloperWorkspace) {
    workspace.recoveredFileDrafts = library.fileEditorRecovery.mapValues { record in
      let version = record.selected(for: workspace.fileEditorRecoveryContext)
      return .init(baseText: version.baseText, text: version.text, context: version.context)
    }
  }

  func captureFileEditorRecovery(from workspace: DeveloperWorkspace) {
    guard libraryLoaded else { return }
    var candidate = library
    var captured: [String: FileEditorRecoveryVersion] = [:]
    for (key, session) in workspace.fileEditorSessions where session.hasUnsavedChanges {
      let version = FileEditorRecoveryVersion(baseText: session.baseText, text: session.text,
        context: workspace.fileEditorRecoveryContext)
      if let existing = candidate.fileEditorRecovery[key] {
        candidate.fileEditorRecovery[key] = existing.merging(version,
          previousContexts: workspace.previousFileEditorRecoveryContexts,
          legacySelection: workspace.fileEditorRecoverySelections[key])
      } else {
        candidate.fileEditorRecovery[key] = .init(baseText: version.baseText, text: version.text, context: version.context)
      }
      captured[key] = version
    }
    do {
      if candidate.fileEditorRecovery != library.fileEditorRecovery { try commitLibrary(candidate) }
      for (key, version) in captured { workspace.fileEditorRecoverySelections[key] = version }
      refreshFileEditorRecovery(in: workspace)
    }
    catch { self.error = "无法保存文件草稿：\(error.localizedDescription)" }
  }
}
