import Foundation

enum GitReviewScope: String, Codable, CaseIterable, Identifiable {
  case unstaged, staged, commit, branch
  var id: String { rawValue }
  var title: String {
    switch self {
    case .unstaged: "未暂存"
    case .staged: "已暂存"
    case .commit: "提交"
    case .branch: "分支"
    }
  }
  var isHistorical: Bool { self == .commit || self == .branch }
}

struct GitReviewChoice: Identifiable, Equatable, Sendable {
  let id: String
  let title: String
}
