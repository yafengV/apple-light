import Foundation
import Observation

@MainActor @Observable
final class ModelCatalog {
  private(set) var models: [String] = []
  private(set) var loading = false
  private(set) var error: String?
  @ObservationIgnored private var generation = UUID()

  nonisolated static func decode(_ data: Data) throws -> [String] {
    struct Response: Decodable {
      struct Model: Decodable { let id: String }
      let data: [Model]
    }
    do {
      let response = try JSONDecoder().decode(Response.self, from: data)
      return Array(Set(response.data.map(\.id).filter {
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      })).sorted()
    } catch {
      throw AgentFailure(message: "服务返回的模型列表格式无效。仍可手动填写模型 ID。")
    }
  }

  func load(
    config: ModelConfiguration,
    fetch: (ModelConfiguration) async throws -> [String] = { config in
      let key = try ModelKeychain.read(account: config.credentialAccount)
      return try await ModelAPIClient().models(config: config, key: key)
    }
  ) async {
    let token = UUID()
    generation = token
    models = []
    error = nil
    loading = true
    defer { if generation == token { loading = false } }
    do {
      let result = try await fetch(config)
      guard !Task.isCancelled, generation == token else { return }
      models = result
    } catch {
      guard !Task.isCancelled, generation == token else { return }
      self.error = error.localizedDescription
    }
  }

  func choices(current: String, query: String) -> [String] {
    let all = current.isEmpty ? models : [current] + models.filter { $0 != current }
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return query.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(query) }
  }
}
