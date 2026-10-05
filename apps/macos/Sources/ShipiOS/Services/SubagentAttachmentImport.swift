import AppKit
import UniformTypeIdentifiers

enum SubagentAttachmentSource: Sendable {
  case file(URL)
  case image(Data, name: String)
}

struct SubagentImportedAttachments: Sendable {
  var images: [ImageAttachment] = []
  var files: [FileAttachment] = []
  func discard(root: URL) {
    for image in images { try? FileManager.default.removeItem(at: ImageAttachmentStorage.url(image, root: root)) }
    for file in files { try? FileManager.default.removeItem(at: FileAttachmentStorage.url(file, root: root)) }
  }
}

enum SubagentAttachmentImport {
  static func load(_ sources: [SubagentAttachmentSource], root: URL,
    imageCount: Int, fileCount: Int) throws -> SubagentImportedAttachments {
    guard !sources.isEmpty, sources.count <= 16 else { throw AgentFailure(message: "一次最多添加 8 个文件和 8 张图片。") }
    var result = SubagentImportedAttachments()
    do {
      for source in sources {
        switch source {
        case .image(let data, let name): result.images.append(try ImageAttachmentStorage.importData(data, name: name, root: root))
        case .file(let url):
          let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
          if !directory, UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
            result.images.append(try ImageAttachmentStorage.importFile(url, root: root))
          } else { result.files.append(try FileAttachmentStorage.importFile(url, root: root)) }
        }
        guard imageCount + result.images.count <= ImageAttachmentStorage.maxCount,
          fileCount + result.files.count <= FileAttachmentStorage.maxCount else {
          throw AgentFailure(message: "每条消息最多添加 8 个文件和 8 张图片。")
        }
      }
      return result
    } catch { result.discard(root: root); throw error }
  }

  @MainActor static func sources(_ providers: [NSItemProvider], timeout: Duration = .seconds(20)) async throws -> [SubagentAttachmentSource] {
    guard !providers.isEmpty, providers.count <= 16 else { throw AgentFailure(message: "一次最多添加 16 个附件。") }
    var result: [SubagentAttachmentSource] = []
    for provider in providers {
      try Task.checkCancellation()
      if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        let bytes = try await data(provider, type: UTType.fileURL.identifier, timeout: timeout)
        guard let url = URL(dataRepresentation: bytes, relativeTo: nil), url.isFileURL else { throw AgentFailure(message: "无法读取粘贴的本机文件。") }
        result.append(.file(url))
      } else if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
        result.append(.image(try await data(provider, type: type, timeout: timeout), name: "粘贴的图片"))
      } else { throw AgentFailure(message: "剪贴板中没有可读取的文件或图片。") }
    }
    return result
  }
  @MainActor private static func data(_ provider: NSItemProvider, type: String, timeout: Duration) async throws -> Data {
    let read = SubagentProviderRead()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { read.start(provider, type: type, timeout: timeout, continuation: $0) }
    } onCancel: {
      Task { @MainActor in read.finish(.failure(CancellationError()), cancel: true) }
    }
  }
}

@MainActor private final class SubagentProviderRead {
  private var continuation: CheckedContinuation<Data, Error>?
  private var result: Result<Data, Error>?
  private var progress: Progress?
  private var deadline: Task<Void, Never>?

  func start(_ provider: NSItemProvider, type: String, timeout: Duration, continuation: CheckedContinuation<Data, Error>) {
    if let result { continuation.resume(with: result); return }
    self.continuation = continuation
    progress = provider.loadDataRepresentation(forTypeIdentifier: type) { [weak self] bytes, error in
      let result: Result<Data, Error> = bytes.map(Result.success)
        ?? .failure(error ?? AgentFailure(message: "无法读取附件。"))
      Task { @MainActor in self?.finish(result) }
    }
    deadline = Task { [weak self] in
      do { try await Task.sleep(for: timeout) } catch { return }
      self?.finish(.failure(AgentFailure(message: "附件读取超时，请重新添加。")), cancel: true)
    }
  }

  func finish(_ result: Result<Data, Error>, cancel: Bool = false) {
    guard self.result == nil else { return }
    self.result = result
    deadline?.cancel(); deadline = nil
    if cancel { progress?.cancel() }
    progress = nil
    continuation?.resume(with: result); continuation = nil
  }
}
