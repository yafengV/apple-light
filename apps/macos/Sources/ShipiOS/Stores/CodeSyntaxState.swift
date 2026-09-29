import Foundation
import Observation

@MainActor @Observable final class CodeSyntaxState {
  private(set) var identity: CodeSyntaxIdentity?
  private(set) var language: String?
  private(set) var error: String?
  private(set) var left: [Int: [CodeSyntaxToken]] = [:]
  private(set) var right: [Int: [CodeSyntaxToken]] = [:]
  private(set) var leftChanges: [Int: [CodeWordRange]] = [:]
  private(set) var rightChanges: [Int: [CodeWordRange]] = [:]
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private let service: any CodeSyntaxHighlighting
  init(service: (any CodeSyntaxHighlighting)? = nil) { self.service = service ?? CodeSyntaxService.shared }
  func load(_ file: GitHubPRCodeFile) async {
    await load(CodeSyntaxInput(file))
  }
  func load(_ input: CodeSyntaxInput) async {
    if identity == input.identity, language != nil { return }
    generation = UUID(); let token = generation
    if identity?.matchesSource(input.identity) != true { left = [:]; right = [:] }
    identity = input.identity; language = nil; error = nil
    leftChanges = [:]; rightChanges = [:]
    do {
      let result = try await service.highlight(input)
      try result.validate(input)
      guard generation == token, !Task.isCancelled else { return }
      left = Dictionary(uniqueKeysWithValues: result.left.map { ($0.id, $0.tokens) })
      right = Dictionary(uniqueKeysWithValues: result.right.map { ($0.id, $0.tokens) })
      leftChanges = Dictionary(uniqueKeysWithValues: result.left.map { ($0.id, $0.changes) })
      rightChanges = Dictionary(uniqueKeysWithValues: result.right.map { ($0.id, $0.changes) })
      language = result.language
    } catch {
      guard generation == token, !Task.isCancelled else { return }
      self.error = error.localizedDescription
    }
  }
  func cancel() { generation = UUID() }
  func changes(_ line: ReviewDiffLine, identity: CodeSyntaxIdentity,
    side: GitHubPRCommentPosition.Side? = nil) -> [CodeWordRange] {
    guard self.identity?.matchesSource(identity) == true, self.identity?.wordDiffs == true else { return [] }
    let side = side ?? (line.kind == .deletion ? .left : .right)
    return (side == .left ? leftChanges[line.id] : rightChanges[line.id]) ?? []
  }
  func tokens(_ line: ReviewDiffLine, in file: GitHubPRCodeFile, side: GitHubPRCommentPosition.Side) -> [CodeSyntaxToken]? {
    tokens(line, identity: .init(path: file.path, fingerprint: file.diff.fingerprint), side: side)
  }
  func tokens(_ line: ReviewDiffLine, identity: CodeSyntaxIdentity, side: GitHubPRCommentPosition.Side? = nil) -> [CodeSyntaxToken]? {
    guard self.identity?.matchesSource(identity) == true else { return nil }
    let side = side ?? (line.kind == .deletion ? .left : .right)
    return side == .left ? left[line.id] : right[line.id]
  }
}
