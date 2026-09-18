import Foundation

struct MemoryDeletionRequest: Identifiable, Equatable {
  enum Kind { case single, all }
  let id = UUID()
  let kind: Kind
  let items: [SavedMemory]

  var title: String { kind == .single ? "删除这条记忆？" : "删除全部本地记忆？" }
  var message: String {
    kind == .single
      ? "此操作将永久删除这条记忆，后续模型请求将不再使用它。"
      : "此操作将永久删除当前 ShipiOS 数据目录中选定的 \(items.count) 条本地记忆。"
  }
}
