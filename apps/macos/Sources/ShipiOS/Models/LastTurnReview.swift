import Foundation

struct LastTurnReviewSource: Equatable, Sendable {
  let runID: String
  let root: URL?
  let diff: CodexTurnDiff?
}

struct LastTurnReviewSnapshot: Sendable {
  let source: LastTurnReviewSource
  let unifiedDiff: String
  let files: [CodexTurnDiffFile]
  let patches: [Int: ReviewDiff]

  static func load(_ source: LastTurnReviewSource, dataRoot: URL) throws -> Self {
    let text = try source.diff.map { try CodexTurnDiffStorage.load($0, root: dataRoot) } ?? ""
    let files = CodexTurnDiffFiles.parse(text)
    return .init(source: source, unifiedDiff: text, files: files,
      patches: Dictionary(uniqueKeysWithValues: files.map { ($0.id, ReviewDiff($0.patch)) }))
  }
}
