import Foundation

private struct MonitoredFileSnapshot: Sendable {
  let revision: WorkspaceFileRevision?
  let text: String?
  let error: String?
}

extension DeveloperWorkspace {
  func stopFileMonitoring() {
    fileMonitorToken = UUID()
    fileMonitorTask?.cancel()
    fileMonitorTask = nil
  }

  func startFileMonitoring(_ path: String) {
    stopFileMonitoring()
    guard let location = try? fileLocation(path),
      FileManager.default.fileExists(atPath: location.url.path) else { return }
    let token = fileMonitorToken
    let key = editorKey(for: path)
    fileMonitorTask = Task { [weak self] in
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
        guard !Task.isCancelled, self.fileMonitorToken == token,
          self.selectedFile == path else { return }
        if self.fileEditorSessions[key]?.saving == true { continue }
        if let text = snapshot.text, let current = snapshot.revision {
          revision = current
          self.applyMonitoredFileText(text, key: key)
        } else if let error = snapshot.error {
          self.recordMonitoredFileError(error, key: key)
        } else {
          revision = snapshot.revision
        }
      }
    }
  }

  private func applyMonitoredFileText(_ text: String, key: String) {
    let large = text.utf8.count > LocalWorkspaceService.maximumEditableTextBytes
    if var session = fileEditorSessions[key] {
      if session.hasUnsavedChanges {
        if !text.utf8.elementsEqual(session.baseText.utf8) {
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
    fileIsReadOnly = large
    fileError = nil
    if !fileText.utf8.elementsEqual(text.utf8) { fileText = text }
  }

  private func recordMonitoredFileError(_ message: String, key: String) {
    if var session = fileEditorSessions[key], session.hasUnsavedChanges {
      session.error = "磁盘文件暂不可读：\(message)"
      fileEditorSessions[key] = session
      fileAutosaveTasks.removeValue(forKey: key)?.cancel()
    } else { fileError = message }
  }
}
