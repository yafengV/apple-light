import Foundation

extension WorkspaceStore {
  /// Additional windows share history/download policy, but never tabs or selection.
  func registerBrowserSession(_ session: BrowserSession) {
    additionalBrowserSessions.add(session)
    session.onVisit = { [weak self] url, title, newVisit in self?.recordBrowserVisit(url, title: title, newVisit: newVisit) }
    session.chooseDownloadDestination = { [weak self] source, filename, completion in
      self?.chooseBrowserDownloadDestination(source: source, filename: filename, completion: completion)
        ?? completion(.cancel)
    }
    session.onDownloadEvent = { [weak self] event in self?.handleBrowserDownload(event) }
  }
}
