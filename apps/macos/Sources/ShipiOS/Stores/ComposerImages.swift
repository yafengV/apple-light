import AppKit
import UniformTypeIdentifiers

enum ImageImport: Sendable {
  case file(URL)
  case bytes(Data, name: String)
}

extension WorkspaceStore {
  var draftImages: [ImageAttachment] { library.draftImages[draftKey] ?? [] }

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

  func preview(_ image: ImageAttachment) {
    previewImage = image
    setOverlay(.imagePreview, presented: true)
  }
}
