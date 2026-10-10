import Foundation
import Observation

/// A connection result belongs only to the configuration that started it.
@MainActor @Observable final class ModelConnectionTest {
  private(set) var testing = false
  private(set) var status = ""
  @ObservationIgnored private var operation: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var snapshot: ModelConfiguration?
  @ObservationIgnored private var keyDraft = ""

  func start(config: ModelConfiguration, keyDraft: String = "",
    test: @escaping @MainActor (ModelConfiguration) async throws -> Int = { config in
      let key = try ModelKeychain.read(account: config.credentialAccount)
      return try await ModelAPIClient().test(config: config, key: key)
    }
  ) {
    cancel()
    snapshot = config
    self.keyDraft = keyDraft
    testing = true
    let token = generation
    operation = Task {
      let result: String
      do {
        let count = try await test(config)
        result = "模型列表可用，服务返回 \(count) 个模型。"
      } catch { result = error.localizedDescription }
      guard generation == token, !Task.isCancelled else { return }
      testing = false
      status = result
      operation = nil
    }
  }

  func invalidateIfChanged(config: ModelConfiguration, keyDraft: String) {
    if let snapshot, snapshot != config || self.keyDraft != keyDraft { cancel() }
  }

  func cancel() {
    generation = UUID()
    operation?.cancel()
    operation = nil
    snapshot = nil
    keyDraft = ""
    testing = false
    status = ""
  }
}
