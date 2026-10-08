import Foundation

@MainActor final class ModelConfigurationReader {
  private let reader: BoundedFileReader<ModelConfiguration?>
  init(url: URL, timeout: Duration = .seconds(15),
    read: @escaping @Sendable (URL) throws -> ModelConfiguration? = { try ModelConfigurationReader.readFile($0) }) {
    reader = BoundedFileReader(url: url, timeout: timeout,
      timeoutMessage: "读取模型配置超时。请检查数据目录是否可访问，然后重试；现有配置和任务记录未被更改。", read: read)
  }
  nonisolated static func readFile(_ url: URL) throws -> ModelConfiguration? {
    do { return try JSONDecoder().decode(ModelConfiguration.self, from: Data(contentsOf: url)) }
    catch CocoaError.fileReadNoSuchFile { return nil }
  }
  func load() async throws -> ModelConfiguration? { try await reader.load() }
  func cancelPending() { reader.cancelPending() }
}
