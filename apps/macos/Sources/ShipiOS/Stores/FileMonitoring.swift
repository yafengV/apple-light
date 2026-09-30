import Foundation

private struct MonitoredFileSnapshot: Sendable {
  let revision: WorkspaceFileRevision?
  let text: String?
  let error: String?
}

extension DeveloperWorkspace {
  func stopFileMonitoring() {
    for task in fileMonitorTasks.values { task.cancel() }
    fileMonitorTasks.removeAll()
    fileMonitorTokens.removeAll()
  }

  func stopFileMonitoring(_ path: String) {
    let key = editorKey(for: path)
    fileMonitorTasks.removeValue(forKey: key)?.cancel()
    fileMonitorTokens.removeValue(forKey: key)
  }

  func startFileMonitoring(_ path: String) {
    stopFileMonitoring(path)
    guard let location = try? fileLocation(path),
      FileManager.default.fileExists(atPath: location.url.path) else { return }
    let key = editorKey(for: path)
    let token = UUID()
    fileMonitorTokens[key] = token
    fileMonitorTasks[key] = Task { [weak self] in
      var revision: WorkspaceFileRevision?
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, let self else { return }
        let previous = revision
        let snapshot = await Task.detached(priority: .utility) { () -> MonitoredFileSnapshot in
          do {
            let current = try LocalWorkspaceService.diskRevision(location.path, root: location.root)
            guard current != previous else { return .init(revision: current, text: nil, error: nil) }
            return .init(revision: current,
              text: try LocalWorkspaceService.read(location.path, root: location.root), error: nil)
          } catch { return .init(revision: nil, text: nil, error: error.localizedDescription) }
        }.value
        guard !Task.isCancelled, self.fileMonitorTokens[key] == token,
          self.openFiles.contains(path) else { return }
        if self.fileEditorSessions[key]?.saving == true { continue }
        if let text = snapshot.text, let current = snapshot.revision {
          revision = current
          self.applyMonitoredFileText(text, key: key, path: path)
        } else if let error = snapshot.error {
          self.recordMonitoredFileError(error, key: key, path: path)
        } else {
          revision = snapshot.revision
        }
      }
    }
  }

  private func applyMonitoredFileText(_ text: String, key: String, path: String) {
    let large = text.utf8.count > LocalWorkspaceService.maximumEditableTextBytes
    if var session = fileEditorSessions[key] {
      if session.hasUnsavedChanges {
        if text.utf8.elementsEqual(session.text.utf8) {
          session.baseText = text
          session.changedOnDisk = nil
          session.error = nil
          fileAutosaveTasks.removeValue(forKey: key)?.cancel()
          fileEditorSessions[key] = large ? nil : session
          recoveredFileDrafts[key] = nil
          onFileEditResolved?(key)
          if selectedFile == path { fileIsReadOnly = large; fileError = nil }
          return
        } else if !text.utf8.elementsEqual(session.baseText.utf8) {
          session.changedOnDisk = text
          session.error = "文件已在应用外更改，请比较两个版本后选择。"
          fileAutosaveTasks.removeValue(forKey: key)?.cancel()
        } else if session.changedOnDisk != nil {
          session.changedOnDisk = nil
          session.error = nil
          scheduleFileAutosave(key: key)
        }
        fileEditorSessions[key] = session
        return
      }
      session.baseText = text
      session.text = text
      session.changedOnDisk = nil
      session.error = nil
      fileEditorSessions[key] = large ? nil : session
    } else if !large {
      fileEditorSessions[key] = FileEditorSession(baseText: text, text: text)
    }
    if selectedFile == path {
      fileIsReadOnly = large
      fileError = nil
      if !fileText.utf8.elementsEqual(text.utf8) { fileText = text }
    }
  }

  private func recordMonitoredFileError(_ message: String, key: String, path: String) {
    if var session = fileEditorSessions[key], session.hasUnsavedChanges {
      session.error = "磁盘文件暂不可读：\(message)"
      fileEditorSessions[key] = session
      fileAutosaveTasks.removeValue(forKey: key)?.cancel()
    } else if selectedFile == path { fileError = message }
  }
}
