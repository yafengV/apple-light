import AppKit
import Foundation

extension WorkspaceStore {
  var browserDownloadPreferences: BrowserDownloadPreferences {
    library.browserDownloadPreferences
  }

  var browserDownloads: [BrowserDownloadRecord] {
    library.browserDownloads.sorted { $0.createdAt > $1.createdAt }
  }

  var browserDownloadDirectory: URL {
    if let path = library.browserDownloadPreferences.directory, !path.isEmpty {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Downloads", isDirectory: true)
  }

  func chooseBrowserDownloadFolder() {
    guard let window = NSApp.keyWindow else { return }
    let panel = NSOpenPanel()
    panel.title = "选择下载文件夹"
    panel.prompt = "选择"
    panel.directoryURL = browserDownloadDirectory
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor in _ = self?.setBrowserDownloadFolder(url) }
    }
  }

  @discardableResult func setBrowserDownloadFolder(_ url: URL) -> Bool {
    let url = url.standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue, FileManager.default.isWritableFile(atPath: url.path)
    else {
      browserSettingsError = "请选择可写入的文件夹。"
      return false
    }
    library.browserDownloadPreferences.directory = url.path
    browserSettingsError = nil
    saveLibrary()
    return true
  }

  func useSystemBrowserDownloadFolder() {
    library.browserDownloadPreferences.directory = nil
    browserSettingsError = nil
    saveLibrary()
  }

  func setBrowserAskWhereToSave(_ value: Bool) {
    library.browserDownloadPreferences.askWhereToSave = value
    saveLibrary()
  }

  func clearFinishedBrowserDownloads() {
    let retained = library.browserDownloads.filter {
      $0.status == .preparing || $0.status == .downloading
    }
    let removedIDs = Set(library.browserDownloads.map(\.id)).subtracting(retained.map(\.id))
    library.browserDownloads = retained
    for id in removedIDs { browserDownloadProgress[id] = nil }
    saveLibrary()
  }

  func removeBrowserDownload(_ id: UUID) {
    guard let record = library.browserDownloads.first(where: { $0.id == id }),
      record.status != .preparing, record.status != .downloading else { return }
    library.browserDownloads.removeAll { $0.id == id }
    browserDownloadProgress[id] = nil
    saveLibrary()
  }

  func cancelBrowserDownload(_ id: UUID) {
    workspace.browser.cancelDownload(id)
    additionalBrowserSessions.allObjects.forEach { $0.cancelDownload(id) }
  }

  @discardableResult func downloadMessageLink(_ url: URL, askWhereToSave: Bool = false) -> UUID? {
    let chooser: BrowserDownloadDestinationChooser? = askWhereToSave ? { [weak self] source, filename, completion in
      self?.chooseBrowserDownloadDestination(source: source, filename: filename, forceAsk: true, completion: completion)
        ?? completion(.cancel)
    } : nil
    guard let id = workspace.browser.downloadLink(url, chooseDestination: chooser) else {
      notices.show(id: "message-link-download", title: "无法开始下载此链接", level: .error)
      return nil
    }
    messageDownloadIDs.insert(id)
    return id
  }

  func openBrowserDownload(_ record: BrowserDownloadRecord) {
    guard let path = record.destinationPath,
      FileManager.default.fileExists(atPath: path) else {
      browserSettingsError = "下载文件已移动或删除。"
      return
    }
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
  }

  func revealBrowserDownload(_ record: BrowserDownloadRecord) {
    guard let path = record.destinationPath,
      FileManager.default.fileExists(atPath: path) else {
      browserSettingsError = "下载文件已移动或删除。"
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
  }

  func automaticBrowserDownloadDestination(filename: String) throws -> URL {
    let directory = browserDownloadDirectory.standardizedFileURL
    var isDirectory: ObjCBool = false
    if !FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      isDirectory = true
    }
    guard isDirectory.boolValue, FileManager.default.isWritableFile(atPath: directory.path) else {
      throw AgentFailure(message: "下载文件夹不可写入。")
    }
    let filename = Self.safeDownloadFilename(filename)
    let base = (filename as NSString).deletingPathExtension
    let extensionName = (filename as NSString).pathExtension
    var candidate = directory.appendingPathComponent(filename, isDirectory: false)
    var suffix = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      let nextName = extensionName.isEmpty
        ? "\(base) \(suffix)" : "\(base) \(suffix).\(extensionName)"
      candidate = directory.appendingPathComponent(nextName, isDirectory: false)
      suffix += 1
    }
    return candidate
  }

  func chooseBrowserDownloadDestination(
    source: URL, filename: String, forceAsk: Bool = false,
    completion: @escaping (BrowserDownloadDestination) -> Void
  ) {
    if !forceAsk && !library.browserDownloadPreferences.askWhereToSave {
      do {
        completion(.save(try automaticBrowserDownloadDestination(filename: filename)))
        browserSettingsError = nil
      } catch {
        browserSettingsError = error.localizedDescription
        completion(.failure(error.localizedDescription))
      }
      return
    }
    guard let window = NSApp.keyWindow else {
      browserSettingsError = "没有可用于选择下载位置的窗口。"
      completion(.failure("没有可用于选择下载位置的窗口。"))
      return
    }
    let panel = NSSavePanel()
    panel.title = "保存下载文件"
    panel.prompt = "保存"
    panel.directoryURL = browserDownloadDirectory
    panel.nameFieldStringValue = Self.safeDownloadFilename(filename)
    panel.message = source.host.map { "来自 \($0)" } ?? "选择文件保存位置"
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url else {
        completion(.cancel)
        return
      }
      do {
        if FileManager.default.fileExists(atPath: url.path) {
          try FileManager.default.removeItem(at: url)
        }
        self?.browserSettingsError = nil
        completion(.save(url))
      } catch {
        self?.browserSettingsError = error.localizedDescription
        completion(.failure(error.localizedDescription))
      }
    }
  }

  func handleBrowserDownload(_ event: BrowserDownloadEvent) {
    switch event {
    case let .started(id, sourceURL, filename):
      if let index = library.browserDownloads.firstIndex(where: { $0.id == id }) {
        library.browserDownloads[index].filename = filename
      } else {
        library.browserDownloads.append(BrowserDownloadRecord(
          id: id, sourceURL: sourceURL, filename: filename, status: .preparing))
      }
      browserDownloadProgress[id] = 0
      trimBrowserDownloadHistory()
      saveLibrary()
    case let .destination(id, url):
      updateBrowserDownload(id) {
        $0.destinationPath = url.path
        $0.filename = url.lastPathComponent
        $0.status = .downloading
      }
    case let .progress(id, fraction):
      browserDownloadProgress[id] = min(max(fraction, 0), 1)
    case let .finished(id):
      messageDownloadIDs.remove(id)
      updateBrowserDownload(id) { record in
        record.status = .finished
        record.message = nil
        if let path = record.destinationPath,
          let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attributes[.size] as? NSNumber
        { record.byteCount = size.int64Value }
      }
      browserDownloadProgress[id] = 1
    case let .failed(id, message):
      if messageDownloadIDs.remove(id) != nil {
        notices.show(id: "message-link-download:\(id)", title: "下载失败：\(message)", level: .error)
      }
      updateBrowserDownload(id) {
        $0.status = .failed
        $0.message = message
      }
      browserDownloadProgress[id] = nil
    case let .cancelled(id):
      messageDownloadIDs.remove(id)
      updateBrowserDownload(id) { $0.status = .cancelled }
      browserDownloadProgress[id] = nil
    }
  }

  private func updateBrowserDownload(
    _ id: UUID, mutate: (inout BrowserDownloadRecord) -> Void
  ) {
    guard let index = library.browserDownloads.firstIndex(where: { $0.id == id }) else { return }
    mutate(&library.browserDownloads[index])
    saveLibrary()
  }

  private func trimBrowserDownloadHistory() {
    guard library.browserDownloads.count > 100 else { return }
    let active = library.browserDownloads.filter {
      $0.status == .preparing || $0.status == .downloading
    }
    let completed = library.browserDownloads.filter {
      $0.status != .preparing && $0.status != .downloading
    }.sorted { $0.createdAt > $1.createdAt }
    library.browserDownloads = active + completed.prefix(max(0, 100 - active.count))
  }

  private static func safeDownloadFilename(_ value: String) -> String {
    let forbidden = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
    let pieces = value.components(separatedBy: forbidden).filter { !$0.isEmpty }
    let sanitized = pieces.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sanitized.isEmpty, sanitized != ".", sanitized != ".." else { return "download" }
    return String(sanitized.prefix(240))
  }
}
