import AppKit
import UniformTypeIdentifiers

extension WorkspaceStore {
  var draftFiles: [FileAttachment] { library.draftFiles[draftKey] ?? [] }

  func pasteAttachments(_ providers: [NSItemProvider]) {
    guard destination == .workspace, !importingFiles, !importingImages, !providers.isEmpty else { return }
    pasteAttachments(providers, draft: draftKey)
  }

  func pasteAttachments(_ providers: [NSItemProvider], draft key: String) {
    guard !importingFiles, !importingImages, !providers.isEmpty else { return }
    guard providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
      pasteImages(providers, draft: key)
      return
    }
    guard providers.count <= FileAttachmentStorage.maxCount + ImageAttachmentStorage.maxCount else {
      error = "一次最多添加 8 个文件和 8 张图片。"; return
    }
    importingFiles = true
    Task {
      do {
        var urls: [URL] = []
        for provider in providers {
          let data: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
              if let data { continuation.resume(returning: data) }
              else { continuation.resume(throwing: error ?? AgentFailure(message: "无法读取粘贴的文件。")) }
            }
          }
          guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
            throw AgentFailure(message: "剪贴板中没有可读取的本机文件。")
          }
          urls.append(url)
        }
        importingFiles = false
        await importDroppedFiles(urls, draft: key)
      } catch { importingFiles = false; self.error = error.localizedDescription }
    }
  }

  func chooseFiles() {
    guard destination == .workspace, !importingFiles, !importingImages, let window = NSApp.keyWindow else { return }
    chooseFiles(draft: draftKey, window: window)
  }

  func chooseFiles(draft key: String) {
    guard let window = NSApp.keyWindow else { return }
    chooseFiles(draft: key, window: window)
  }

  func chooseFiles(draft key: String, window: NSWindow) {
    guard !importingFiles, !importingImages else { return }
    let panel = NSOpenPanel()
    panel.title = "添加文件"
    panel.message = "文本、代码、CSV、JSON 或 PDF；每个文件最多 5 MiB。PDF 仅提取文字。"
    panel.allowsMultipleSelection = true
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.data]
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK else { return }
      let urls = panel.urls
      Task { @MainActor in _ = await self?.importFiles(urls, draft: key) }
    }
  }

  @discardableResult func importFiles(_ urls: [URL], draft key: String? = nil) async -> Bool {
    guard libraryLoaded, !shuttingDown, !importingFiles, !importingImages, !urls.isEmpty else { return false }
    let key = key ?? draftKey
    guard urls.count + (library.draftFiles[key]?.count ?? 0) <= FileAttachmentStorage.maxCount else {
      error = "每条消息最多添加 8 个文件。"; return false
    }
    importingFiles = true
    defer { importingFiles = false }
    let root = dataRoot
    do {
      let files = try await Task.detached(priority: .userInitiated) {
        var result: [FileAttachment] = []
        do {
          for url in urls { result.append(try FileAttachmentStorage.importFile(url, root: root)) }
          return result
        } catch {
          for file in result { try? FileManager.default.removeItem(at: FileAttachmentStorage.url(file, root: root)) }
          throw error
        }
      }.value
      do {
        guard !shuttingDown else { throw CancellationError() }
        var candidate = library
        candidate.draftFiles[key, default: []].append(contentsOf: files)
        try candidate.save(to: root.appendingPathComponent("workspace.json"))
        library = candidate
      } catch {
        for file in files { try? FileManager.default.removeItem(at: FileAttachmentStorage.url(file, root: root)) }
        throw error
      }
      error = nil
      if draftKey == key, destination == .workspace { action = .chat; focusComposer = UUID() }
      return true
    } catch { self.error = error.localizedDescription; return false }
  }

  func importDroppedFiles(_ urls: [URL], draft key: String) async {
    // Import by type so ordinary files no longer enter the image decoder.
    let images = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
    let files = urls.filter { !images.contains($0) }
    if !files.isEmpty, !(await importFiles(files, draft: key)) { return }
    if !images.isEmpty { _ = await importImages(images.map(ImageImport.file), draft: key) }
  }

  func removeDraftFile(_ file: FileAttachment, draft key: String? = nil) {
    guard libraryLoaded else { return }
    do {
      var candidate = library
      candidate.draftFiles[key ?? draftKey]?.removeAll { $0.id == file.id }
      try commitLibrary(candidate)
    } catch { self.error = error.localizedDescription }
  }

  func preview(_ file: FileAttachment) {
    previewFile = file
    setOverlay(.filePreview, presented: true)
  }
}
