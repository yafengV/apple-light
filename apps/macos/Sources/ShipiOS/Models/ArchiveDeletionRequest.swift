import Foundation

struct ArchiveDeletionRequest: Identifiable, Equatable {
  enum Kind { case task, single, project, all }
  let id = UUID()
  let kind: Kind
  let taskIDs: Set<String>

  var title: String {
    switch kind {
    case .task: "永久删除任务？"
    case .single: "删除归档任务？"
    case .project: "删除项目中的全部归档任务？"
    case .all: "删除全部本地归档任务？"
    }
  }
  var message: String {
    switch kind {
    case .task: "此操作将永久删除此任务及其会话记录，无法恢复。"
    case .single: "此操作将永久删除这条归档任务。"
    case .project: "此操作将永久删除此项目中的 \(taskIDs.count) 条本地归档任务。"
    case .all: "此操作将永久删除全部本地归档任务。"
    }
  }
}
