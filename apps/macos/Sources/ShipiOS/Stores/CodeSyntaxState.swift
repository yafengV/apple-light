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
  init(service: any CodeSyntaxHighlighting = CodeSyntaxService.shared) { self.service = service }
  func load(_ file: GitHubPRCodeFile) async {
    let input = CodeSyntaxInput(file)
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
    guard identity == CodeSyntaxIdentity(path: file.path, fingerprint: file.diff.fingerprint) else { return nil }
    return side == .left ? left[line.id] : right[line.id]
  }
}
