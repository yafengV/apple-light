import Foundation

extension WorkspaceStore {
  func bindFileEditorRecovery(to workspace: DeveloperWorkspace,
    context: FileEditorRecoveryContext = .init(kind: .mainTree)) {
    if let previous = workspace.fileEditorRecoveryContext, previous != context {
      workspace.previousFileEditorRecoveryContexts.insert(previous)
    }
    workspace.fileEditorRecoveryContext = context
    workspace.fileEditingAllowed = { [weak self] in self?.shuttingDown == false }
    refreshFileEditorRecovery(in: workspace)
    workspace.onFileEditResolved = { [weak self, weak workspace] key in
      guard let self, let workspace, let selection = workspace.fileEditorRecoverySelections[key] else { return }
      workspace.pendingFileEditorRecoveryResolutions.insert(key)
      var candidate = self.library
      candidate.fileEditorRecovery[key] = candidate.fileEditorRecovery[key]?.removing(selection)
      do {
        if candidate.fileEditorRecovery != self.library.fileEditorRecovery { try self.commitLibrary(candidate) }
        workspace.fileEditorRecoverySelections[key] = nil
        workspace.pendingFileEditorRecoveryResolutions.remove(key)
        if !workspace.fileEditorSessions.values.contains(where: \.hasUnsavedChanges),
          workspace.pendingFileEditorRecoveryResolutions.isEmpty {
          self.pendingFileEditorRecoveryWorkspaces[ObjectIdentifier(workspace)] = nil
        }
        self.clearFileEditorRecoveryErrorIfResolved()
      }
      catch { self.retainFailedFileEditorRecovery([workspace], message: "无法更新文件草稿记录：\(error.localizedDescription)") }
    }
  }

  private func refreshFileEditorRecovery(in workspace: DeveloperWorkspace) {
    workspace.recoveredFileDrafts = library.fileEditorRecovery.mapValues { record in
      let version = record.selected(for: workspace.fileEditorRecoveryContext)
      return .init(baseText: version.baseText, text: version.text, context: version.context)
    }
  }

  @discardableResult func captureFileEditorRecovery(from workspace: DeveloperWorkspace) -> Bool {
    captureFileEditorRecovery(from: [workspace])
  }

  @discardableResult func captureFileEditorRecovery(from requested: [DeveloperWorkspace],
    includePending: Bool = true, forceSave: Bool = false) -> Bool {
    var unique: [ObjectIdentifier: DeveloperWorkspace] = includePending ? pendingFileEditorRecoveryWorkspaces : [:]
    for workspace in requested { unique[ObjectIdentifier(workspace)] = workspace }
    let workspaces = Array(unique.values)
    let needsStorage = workspaces.contains {
      $0.fileEditorSessions.values.contains(where: \.hasUnsavedChanges) || !$0.pendingFileEditorRecoveryResolutions.isEmpty
    }
    guard needsStorage else {
      for id in unique.keys { pendingFileEditorRecoveryWorkspaces[id] = nil }
      clearFileEditorRecoveryErrorIfResolved()
      return true
    }
    guard libraryLoaded else {
      retainFailedFileEditorRecovery(workspaces, message: "工作区尚未加载，文件草稿未保存。请完成恢复后重试关闭或退出。")
      return false
    }
    var candidate = library
    var captures: [(DeveloperWorkspace, [String: FileEditorRecoveryVersion], Set<String>)] = []
    // Apply all explicit resolutions before adding current drafts. A discarded
    // pending version must not return when its window has already disappeared.
    for workspace in workspaces {
      for key in workspace.pendingFileEditorRecoveryResolutions {
        if let selection = workspace.fileEditorRecoverySelections[key] {
          candidate.fileEditorRecovery[key] = candidate.fileEditorRecovery[key]?.removing(selection)
        }
      }
    }
    for workspace in workspaces {
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
      captures.append((workspace, captured, workspace.pendingFileEditorRecoveryResolutions))
    }
    do {
      if forceSave || candidate.fileEditorRecovery != library.fileEditorRecovery { try commitLibrary(candidate) }
      for (workspace, captured, resolved) in captures {
        for key in resolved { workspace.fileEditorRecoverySelections[key] = nil }
        workspace.pendingFileEditorRecoveryResolutions.subtract(resolved)
        for (key, version) in captured { workspace.fileEditorRecoverySelections[key] = version }
        refreshFileEditorRecovery(in: workspace)
        for key in resolved where captured[key] == nil { workspace.recoveredFileDrafts[key] = nil }
        pendingFileEditorRecoveryWorkspaces[ObjectIdentifier(workspace)] = nil
      }
      clearFileEditorRecoveryErrorIfResolved()
      return true
    } catch {
      retainFailedFileEditorRecovery(workspaces, message: "无法保存文件草稿：\(error.localizedDescription)")
      return false
    }
  }

  private func retainFailedFileEditorRecovery(_ workspaces: [DeveloperWorkspace], message: String) {
    for workspace in workspaces where workspace.fileEditorSessions.values.contains(where: \.hasUnsavedChanges)
      || !workspace.pendingFileEditorRecoveryResolutions.isEmpty {
      pendingFileEditorRecoveryWorkspaces[ObjectIdentifier(workspace)] = workspace
    }
    error = message; fileEditorRecoveryError = message
    notices.show(id: "file-recovery-save", title: message,
      description: "未保存的编辑仍暂存在本次运行中。请检查数据目录后重试关闭或退出。", level: .error)
  }

  private func clearFileEditorRecoveryErrorIfResolved() {
    guard pendingFileEditorRecoveryWorkspaces.isEmpty else { return }
    if error == fileEditorRecoveryError { error = nil }
    fileEditorRecoveryError = nil
    notices.completeAndDismiss("file-recovery-save")
  }

  func prepareMainWindowClose() -> Bool {
    let mainFiles = fileTabWorkspaces.filter { workspaceTabPlacement($0.key) != .detached }.map(\.value)
    return captureFileEditorRecovery(from: [workspace] + mainFiles, includePending: false, forceSave: true)
  }

  func prepareDetachedWindowClose(_ tabID: String?) -> Bool {
    captureFileEditorRecovery(from: tabID.flatMap { fileTabWorkspaces[$0] }.map { [$0] } ?? [],
      includePending: false, forceSave: true)
  }
}
