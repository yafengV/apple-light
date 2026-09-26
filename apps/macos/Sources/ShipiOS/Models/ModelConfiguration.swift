import Foundation

enum ModelAPIProtocol: String, Codable, CaseIterable {
  case chatCompletions
  case codexResponses
}

struct TaskModelSelection: Codable, Equatable {
  let model: String
  let reasoning: String
  /// Model IDs are local to the configured service, not portable across providers.
  let providerAccount: String
  /// Legacy selections predate protocol choice and always used Chat Completions.
  var apiProtocol: ModelAPIProtocol? = nil
}

struct ModelConfiguration: Codable, Equatable {
  var baseURL = ""
  var model = ""
  var reasoning = ""
  var apiProtocol: ModelAPIProtocol = .chatCompletions
  /// New configurations request authoritative usage. Legacy providers stay unchanged until enabled.
  var includeUsage = true
  /// The configured Responses endpoint accepts OpenAI hosted web_search tools.
  var supportsHostedWebSearch = false
  /// Retained only for migration from model.json to the independent AGENTS.md.
  var instructions = Personalization.baseInstructions

  init() {}
  enum CodingKeys: String, CodingKey {
    case baseURL, model, reasoning, apiProtocol, includeUsage, supportsHostedWebSearch, instructions
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
    model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
    reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning) ?? ""
    apiProtocol = try c.decodeIfPresent(ModelAPIProtocol.self, forKey: .apiProtocol)
      ?? .chatCompletions
    includeUsage = try c.decodeIfPresent(Bool.self, forKey: .includeUsage) ?? false
    supportsHostedWebSearch = try c.decodeIfPresent(Bool.self, forKey: .supportsHostedWebSearch) ?? false
    instructions = try c.decodeIfPresent(String.self, forKey: .instructions)
      ?? Personalization.baseInstructions
  }

  func endpoint(_ path: String) throws -> URL {
    guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
      let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
      url.query == nil, url.fragment == nil,
      url.scheme == "https"
        || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host))
    else {
      throw AgentFailure(
        message: "API 地址须使用 HTTPS；本机 localhost 可使用 HTTP。请填写包含 /v1 的基础地址，不要在地址中包含密钥。")
    }
    return url.appendingPathComponent(path)
  }
  func validateEndpoint() throws {
    _ = try endpoint(apiProtocol == .codexResponses ? "responses" : "chat/completions")
  }
  var credentialAccount: String {
    baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(
      in: CharacterSet(charactersIn: "/"))
  }
}

struct ChatStreamDelta {
  let text: String
  let finished: Bool
  let choiceFinished: Bool
  let usage: ModelTokenUsage?
  var toolFragments: [JSONValue] = []
  var finishReason: String?
  static func parse(_ line: String) throws -> Self? {
    guard line.hasPrefix("data:") else { return nil }
    let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
    if json == "[DONE]" {
      return Self(text: "", finished: true, choiceFinished: false, usage: nil)
    }
    guard json.utf8.count <= 262_144 else { throw AgentFailure(message: "模型返回的数据帧过大。") }
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    if value["error"] != .null { throw AgentFailure(message: "模型服务返回错误，请检查模型与 API 配置。") }
    let choice = value["choices"].items.first ?? .null
    return Self(
      text: choice["delta"]["content"].text ?? "", finished: false,
      choiceFinished: choice["finish_reason"].text != nil,
      usage: ModelTokenUsage(value["usage"]), toolFragments: choice["delta"]["tool_calls"].items,
      finishReason: choice["finish_reason"].text)
  }
}
