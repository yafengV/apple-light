import Foundation

extension DeveloperWorkspace {
  func editorKey(for path: String) -> String {
    if let location = try? fileLocation(path) { return location.url.path }
    if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL.path }
    return (root?.path ?? "") + "/" + path
  }

  var selectedFileEditor: FileEditorSession? {
    guard let selectedFile else { return nil }
    return fileEditorSessions[editorKey(for: selectedFile)]
  }

  func beginEditingSelectedFile() {
    guard let selectedFile, !fileLoading, fileError == nil else { return }
    let key = editorKey(for: selectedFile)
    if fileEditorSessions[key] == nil {
      fileEditorSessions[key] = FileEditorSession(baseText: fileText, text: fileText)
    }
    fileFocusRequest = UUID()
  }

  func editSelectedFile(_ text: String) {
    guard let selectedFile else { return }
    let key = editorKey(for: selectedFile)
    guard var session = fileEditorSessions[key] else { return }
    session.text = text
    session.error = nil
    fileEditorSessions[key] = session
    fileText = text
    if session.changedOnDisk == nil { scheduleFileAutosave(key: key) }
  }

  private func scheduleFileAutosave(key: String) {
    fileAutosaveTasks.removeValue(forKey: key)?.cancel()
    guard fileEditorSessions[key]?.hasUnsavedChanges == true else { return }
    fileAutosaveTasks[key] = Task { [weak self] in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      guard let self else { return }
      self.fileAutosaveTasks[key] = nil
      _ = await self.saveFileEdits(key: key)
    }
  }

  @discardableResult func saveSelectedFileEdits() async -> Bool {
    guard let selectedFile else { return false }
    return await saveFileEdits(key: editorKey(for: selectedFile))
  }

  @discardableResult func saveFileEdits(key: String) async -> Bool {
    fileAutosaveTasks.removeValue(forKey: key)?.cancel()
    guard var session = fileEditorSessions[key] else { return false }
    guard !session.saving, session.changedOnDisk == nil else { return false }
    guard session.hasUnsavedChanges else { return true }
    guard let location = try? WorkspaceFileScope.location(key, roots: fileRoots) else {
      session.error = "文件已不在当前项目关联的目录内，未保存。"
      fileEditorSessions[key] = session
      return false
    }
    let expected = session.baseText, replacement = session.text
    session.saving = true
    session.error = nil
    fileEditorSessions[key] = session
    do {
      let result = try await Task.detached(priority: .userInitiated) {
        try LocalWorkspaceService.saveEditedFile(location.path, root: location.root,
          expected: expected, replacement: replacement)
      }.value
      guard var current = fileEditorSessions[key] else { return false }
      current.saving = false
      switch result {
      case .saved:
        current.baseText = replacement
        current.error = nil
        fileEditorSessions[key] = current
        if current.hasUnsavedChanges { scheduleFileAutosave(key: key) }
        else {
          recoveredFileDrafts[key] = nil
          onFileEditResolved?(key)
        }
        return true
      case .changedOnDisk(let diskText):
        current.changedOnDisk = diskText
        current.error = "文件已在应用外更改，请选择保留磁盘版本或使用当前编辑内容。"
        fileEditorSessions[key] = current
        return false
      }
    } catch {
      guard var current = fileEditorSessions[key] else { return false }
      current.saving = false
      current.error = error.localizedDescription
      fileEditorSessions[key] = current
      return false
    }
  }

  @discardableResult func useLocalFileEditsAfterConflict() async -> Bool {
    guard let selectedFile else { return false }
    let key = editorKey(for: selectedFile)
    guard var session = fileEditorSessions[key], let diskText = session.changedOnDisk else { return false }
    session.baseText = diskText
    session.changedOnDisk = nil
    session.error = nil
    fileEditorSessions[key] = session
    return await saveFileEdits(key: key)
  }

  func discardSelectedFileEdits() {
    guard let selectedFile else { return }
    let key = editorKey(for: selectedFile)
    fileAutosaveTasks.removeValue(forKey: key)?.cancel()
    fileEditorSessions[key] = nil
    recoveredFileDrafts[key] = nil
    onFileEditResolved?(key)
    selectFile(selectedFile)
  }

  func discardAndCloseFile(_ path: String) {
    let key = editorKey(for: path)
    fileAutosaveTasks.removeValue(forKey: key)?.cancel()
    fileEditorSessions[key] = nil
    recoveredFileDrafts[key] = nil
    onFileEditResolved?(key)
    fileCloseRequest = nil
    closeFile(path)
  }
}
