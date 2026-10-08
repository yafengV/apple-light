import Foundation

@MainActor final class WorkspaceLibraryReader {
  private let reader: BoundedFileReader<WorkspaceLibrary>
  init(url: URL, timeout: Duration = .seconds(15),
    read: @escaping @Sendable (URL) throws -> WorkspaceLibrary = { try WorkspaceLibrary.load(from: $0) }) {
    reader = BoundedFileReader(url: url, timeout: timeout,
      timeoutMessage: "读取工作区记录超时。请检查数据目录是否可访问，然后重试；现有记录未被更改。", read: read)
  }
  func load() async throws -> WorkspaceLibrary { try await reader.load() }
}
