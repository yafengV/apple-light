import Foundation

enum GitPullRequestAction: String, CaseIterable, Identifiable {
  case createDraft, create, openBrowser, openExisting
  var id: Self { self }
  static let creationActions: [Self] = [.createDraft, .create, .openBrowser]
  static func initial(existing: Bool, defaultToDraft: Bool) -> Self {
    existing ? .openExisting : defaultToDraft ? .createDraft : .create
  }
  func moved(by delta: Int, existing: Bool) -> Self {
    let actions: [Self] = existing ? [.openExisting] : Self.creationActions
    let index = actions.firstIndex(of: self) ?? 0
    return actions[((index + delta) % actions.count + actions.count) % actions.count]
  }
  var title: String {
    switch self {
    case .createDraft: "创建草稿 PR"
    case .create: "创建 PR"
    case .openBrowser, .openExisting: "在浏览器中打开 PR"
    }
  }
  var symbol: String {
    switch self {
    case .createDraft: "doc.badge.clock"
    case .create: "arrow.triangle.pull"
    case .openBrowser, .openExisting: "arrow.up.right.square"
    }
  }
}
