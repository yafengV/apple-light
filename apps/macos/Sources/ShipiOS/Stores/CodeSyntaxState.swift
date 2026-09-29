import Foundation
import Observation

@MainActor @Observable final class CodeSyntaxState {
  private(set) var identity: CodeSyntaxIdentity?
  private(set) var language: String?
  private(set) var error: String?
  private(set) var left: [Int: [CodeSyntaxToken]] = [:]
  private(set) var right: [Int: [CodeSyntaxToken]] = [:]
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private let service: any CodeSyntaxHighlighting
  init(service: (any CodeSyntaxHighlighting)? = nil) { self.service = service ?? CodeSyntaxService.shared }
  func load(_ file: GitHubPRCodeFile) async {
    await load(CodeSyntaxInput(file))
  }
  func load(_ input: CodeSyntaxInput) async {
    if identity == input.identity, language != nil { return }
    generation = UUID(); let token = generation
    identity = input.identity; language = nil; left = [:]; right = [:]; error = nil
    do {
      let result = try await service.highlight(input)
      try result.validate(input)
      guard generation == token, !Task.isCancelled else { return }
      left = Dictionary(uniqueKeysWithValues: result.left.map { ($0.id, $0.tokens) })
      right = Dictionary(uniqueKeysWithValues: result.right.map { ($0.id, $0.tokens) })
      language = result.language
    } catch {
      guard generation == token, !Task.isCancelled else { return }
      self.error = error.localizedDescription
    }
  }
  func cancel() { generation = UUID() }
  func tokens(_ line: ReviewDiffLine, in file: GitHubPRCodeFile, side: GitHubPRCommentPosition.Side) -> [CodeSyntaxToken]? {
    tokens(line, identity: .init(path: file.path, fingerprint: file.diff.fingerprint), side: side)
  }
  func tokens(_ line: ReviewDiffLine, identity: CodeSyntaxIdentity, side: GitHubPRCommentPosition.Side? = nil) -> [CodeSyntaxToken]? {
    guard self.identity == identity else { return nil }
    let side = side ?? (line.kind == .deletion ? .left : .right)
    return side == .left ? left[line.id] : right[line.id]
  }
}
