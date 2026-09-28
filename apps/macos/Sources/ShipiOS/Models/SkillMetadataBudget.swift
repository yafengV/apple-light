import Foundation

enum SkillMetadataBudget: Equatable {
  case characters(Int)
  case tokens(Int)

  static func forModel(contextWindow: Int?, maxContextTokens: Int? = nil) -> Self {
    if let configured = maxContextTokens, configured > 0 { return .tokens(min(configured, 10_000)) }
    guard let window = contextWindow, window > 0 else { return .characters(8_000) }
    return .tokens(max(1, (window / 100) * 2 + (window % 100) * 2 / 100))
  }

  var limit: Int {
    switch self { case .characters(let value), .tokens(let value): return max(0, value) }
  }
  var unit: String {
    switch self { case .characters: return "characters"; case .tokens: return "approximate_tokens" }
  }
  func cost(_ text: String) -> Int { cost(characters: text.count, bytes: text.utf8.count) }
  func cost(characters: Int, bytes: Int) -> Int {
    switch self {
    case .characters: return characters
    case .tokens: return bytes / 4 + (bytes % 4 == 0 ? 0 : 1)
    }
  }
}

struct ModelCatalogSource: Hashable {
  let account: String
  let apiProtocol: ModelAPIProtocol
  init(_ config: ModelConfiguration) {
    account = config.credentialAccount
    apiProtocol = config.apiProtocol
  }
}
