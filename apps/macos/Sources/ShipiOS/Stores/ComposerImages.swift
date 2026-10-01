import AppKit
import UniformTypeIdentifiers

enum ImageImport: Sendable {
  case file(URL)
  case bytes(Data, name: String)
  case appshot(Data, name: String, context: AppshotContext, id: UUID?)
}

extension WorkspaceStore {
  var draftImages: [ImageAttachment] { library.draftImages[draftKey] ?? [] }

  func captureAppshot(draft key: String, target: AppshotTarget? = nil) async {
    await captureAppshotWithProgress(draft: key) { progress in
      try await appshotCapture.capture(target: target, onScreenshot: progress)
    }
  }

  func captureAppshot(draft key: String,
    ownerWindow: NSWindow? = nil,
    capture: () async throws -> AppshotCaptureResult?) async {
    await captureAppshotWithProgress(draft: key, ownerWindow: ownerWindow) { _ in try await capture() }
  }

  func captureAppshotWithProgress(draft key: String,
    ownerWindow: NSWindow? = nil,
    capture: (@escaping (AppshotCaptureResult) -> Void) async throws -> AppshotCaptureResult?) async {
    guard libraryLoaded, !shuttingDown, !importingImages, !importingFiles else { return }
    guard (library.draftImages[key]?.count ?? 0) < ImageAttachmentStorage.maxCount else {
      error = "每条消息最多添加 8 张图片。"
      return
    }
    let captureOwner = ownerWindow ?? NSApp?.keyWindow
    importingImages = true
    let progress: (AppshotCaptureResult) -> Void = { [weak self, weak captureOwner] screenshot in
      guard let self, self.importingImages, self.pendingAppshot == nil else { return }
      let id = UUID()
      self.pendingAppshot = PendingAppshot(id: id, draftKey: key, result: screenshot)
      self.prepareAppshotHandoff(id: id, screenshot: screenshot,
        ownerWindow: captureOwner)
    }
    do {
      let result = try await capture(progress)
      importingImages = false
      guard let result else {
        clearPendingAppshot(draft: key, cancelHandoff: true)
        return
      }
      if result.context == nil { clearPendingAppshot(draft: key, cancelHandoff: true) }
      let pendingID = pendingAppshot?.draftKey == key ? pendingAppshot?.id : nil
      let item: ImageImport = result.context.map {
        .appshot(result.data, name: result.name, context: $0, id: pendingID)
      } ?? .bytes(result.data, name: result.name)
      let imported = await importImages([item], draft: key)
      clearPendingAppshot(draft: key, cancelHandoff: !imported)
      guard pendingID == nil else { return }
      guard imported, let sourceFrame = result.sourceFrame,
        let captureOwner, !appearance.shouldReduceMotion,
        let attachment = library.draftImages[key]?.last,
        attachment.name == result.name else { return }
      prepareAppshotHandoff(id: attachment.id, screenshot: result,
        ownerWindow: captureOwner, sourceFrame: sourceFrame)
    } catch {
      importingImages = false
      clearPendingAppshot(draft: key, cancelHandoff: true)
      self.error = error.localizedDescription
    }
  }

  private func prepareAppshotHandoff(id: UUID, screenshot: AppshotCaptureResult,
    ownerWindow: NSWindow?, sourceFrame: CGRect? = nil) {
    guard let sourceFrame = sourceFrame ?? screenshot.sourceFrame,
      let ownerWindow, ownerWindow.isVisible, !ownerWindow.isMiniaturized,
      !appearance.shouldReduceMotion else { return }
    appshotHandoffAnimator.cancel()
    appshotHandoffStarted = false
    appshotHandoff = AppshotHandoff(imageID: id, ownerWindow: ownerWindow,
      sourceFrame: sourceFrame, screenshot: screenshot.data)
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(2))
      guard let self, self.appshotHandoff?.imageID == id else { return }
      self.appshotHandoffAnimator.cancel()
      self.appshotHandoff = nil
      self.appshotHandoffStarted = false
    }
  }

  private func clearPendingAppshot(draft key: String, cancelHandoff: Bool = false) {
    guard let pending = pendingAppshot, pending.draftKey == key else { return }
    pendingAppshot = nil
    if cancelHandoff, appshotHandoff?.imageID == pending.id {
      appshotHandoffAnimator.cancel()
      appshotHandoff = nil
      appshotHandoffStarted = false
    }
  }

  func startAppshotHandoff(imageID: UUID, destinationFrame: CGRect, window: NSWindow) {
    guard let handoff = appshotHandoff, handoff.imageID == imageID,
      handoff.ownerWindow === window, window.isVisible,
      !window.isMiniaturized, !appshotHandoffStarted else { return }
    let visible = destinationFrame.intersection(window.frame)
    guard !visible.isNull, visible.width >= destinationFrame.width * 0.5,
      visible.height >= destinationFrame.height * 0.5 else { return }
    appshotHandoffStarted = true
    let started = appshotHandoffAnimator.start(handoff, destinationFrame: destinationFrame) { [weak self] in
      guard let self, self.appshotHandoff?.imageID == imageID else { return }
      self.appshotHandoff = nil
      self.appshotHandoffStarted = false
    }
    if !started {
      appshotHandoff = nil
      appshotHandoffStarted = false
    }
  }

  func chooseImages() {
    guard destination == .workspace, !importingImages, !importingFiles, let window = NSApp.keyWindow else { return }
    chooseImages(draft: draftKey, window: window)
  }

  func chooseImages(draft key: String) {
    guard let window = NSApp.keyWindow else { return }
    chooseImages(draft: key, window: window)
  }

  func chooseImages(draft key: String, window: NSWindow) {
    guard !importingImages, !importingFiles else { return }
    let panel = NSOpenPanel()
    panel.title = "添加图片"
    panel.allowedContentTypes = [.png, .jpeg, .webP, .gif, .tiff]
    panel.allowsMultipleSelection = true
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK else { return }
      let items = panel.urls.map(ImageImport.file)
      Task { @MainActor in _ = await self?.importImages(items, draft: key) }
    }
  }

  func pasteImages(_ providers: [NSItemProvider]) {
    guard destination == .workspace, !importingImages, !importingFiles else { return }
    pasteImages(providers, draft: draftKey)
  }

  func pasteImages(_ providers: [NSItemProvider], draft key: String) {
    guard !importingImages, !importingFiles else { return }
    guard providers.count <= ImageAttachmentStorage.maxCount else {
      error = "每条消息最多添加 8 张图片。"
      return
    }
    // Capture ownership before asynchronous pasteboard/provider reads.
    importingImages = true
    Task {
      do {
        var imports: [ImageImport] = []
        for provider in providers {
          guard
            let type = [UTType.png, .jpeg, .webP, .gif, .tiff].first(where: {
              provider.hasItemConformingToTypeIdentifier($0.identifier)
            })
          else { throw AgentFailure(message: "剪贴板中没有支持的图片。") }
          let data: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
              if let data {
                continuation.resume(returning: data)
              } else {
                continuation.resume(throwing: error ?? AgentFailure(message: "无法读取剪贴板图片。"))
              }
            }
          }
          imports.append(.bytes(data, name: "粘贴的图片." + (type.preferredFilenameExtension ?? "png")))
        }
        importingImages = false
        _ = await importImages(imports, draft: key)
      } catch {
        importingImages = false
        self.error = error.localizedDescription
      }
    }
  }

  @discardableResult func importImages(_ items: [ImageImport], draft key: String? = nil) async
    -> Bool
  {
    guard libraryLoaded, !shuttingDown, !importingImages, !importingFiles, !items.isEmpty else { return false }
    let key = key ?? draftKey
    guard items.count + (library.draftImages[key]?.count ?? 0) <= ImageAttachmentStorage.maxCount
    else {
      error = "每条消息最多添加 8 张图片。"
      return false
    }
    importingImages = true
    defer { importingImages = false }
    let root = dataRoot
    do {
      let images = try await Task.detached(priority: .userInitiated) {
        var result: [ImageAttachment] = []
        do {
          for item in items {
            switch item {
            case .file(let url):
              result.append(try ImageAttachmentStorage.importFile(url, root: root))
            case .bytes(let data, let name):
              result.append(try ImageAttachmentStorage.importData(data, name: name, root: root))
            case .appshot(let data, let name, let context, let id):
              result.append(try ImageAttachmentStorage.importData(data, name: name, root: root,
                appshot: context, id: id ?? UUID()))
            }
          }
          return result
        } catch {
          for image in result {
            try? FileManager.default.removeItem(at: ImageAttachmentStorage.url(image, root: root))
          }
          throw error
        }
      }.value
      do {
        var candidate = library
        candidate.draftImages[key, default: []].append(contentsOf: images)
        try candidate.save(to: dataRoot.appendingPathComponent("workspace.json"))
        library = candidate
      } catch {
        for image in images {
          try? FileManager.default.removeItem(at: ImageAttachmentStorage.url(image, root: root))
        }
        throw error
      }
      error = nil
      if draftKey == key, destination == .workspace {
        action = .chat
        focusComposer = UUID()
      }
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  func removeDraftImage(_ image: ImageAttachment, draft key: String? = nil) {
    guard libraryLoaded else { return }
    do {
      var candidate = library
      candidate.draftImages[key ?? draftKey]?.removeAll { $0.id == image.id }
      try commitLibrary(candidate)
    } catch { self.error = error.localizedDescription }
  }

  func preview(_ image: ImageAttachment, images: [ImageAttachment] = []) {
    preview(ImagePreviewItem(image), images: images.map(ImagePreviewItem.init))
  }

  func preview(_ image: ImagePreviewItem, images: [ImagePreviewItem]) {
    guard !hasSettingsConfirmation, presentedOverlay == nil else { return }
    previewImages = images.contains(where: { $0.id == image.id }) ? images : [image]
    previewImage = image
    setOverlay(.imagePreview, presented: true)
  }
}
