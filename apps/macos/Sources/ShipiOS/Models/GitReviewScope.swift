import Foundation

enum GitReviewScope: String, Codable, CaseIterable, Identifiable {
  case unstaged, staged, commit, branch, lastTurn
  var id: String { rawValue }
  var title: String {
    switch self {
    case .unstaged: "未暂存"
    case .staged: "已暂存"
    case .commit: "提交"
    case .branch: "分支"
    case .lastTurn: "最近一轮"
    }
  }
  var isHistorical: Bool { self == .commit || self == .branch || self == .lastTurn }
}

struct GitReviewChoice: Identifiable, Equatable, Sendable {
  let id: String
  let title: String
}
