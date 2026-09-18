import AppKit

@MainActor enum ExternalEditorService {
  static func available(_ editor: ExternalEditor) -> Bool {
    guard let bundleID = editor.bundleID else { return true }
    return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
  }

  static func open(_ path: String, root: URL, line: Int?, editor: ExternalEditor) async throws {
    let file = try LocalWorkspaceService.resolvedFile(path, root: root)
    let values = try file.resourceValues(forKeys: [.isRegularFileKey])
    guard values.isRegularFile == true else {
      throw AgentFailure(message: "此文件已不在工作区中，或不是普通文件。仍可在审查页查看历史差异。")
    }
    var selected = editor
    if selected == .system, line != nil,
      let application = NSWorkspace.shared.urlForApplication(toOpen: file),
      let bundleID = Bundle(url: application)?.bundleIdentifier,
      let supported = ExternalEditor.allCases.first(where: { $0.bundleID == bundleID })
    {
      selected = supported
    }
    guard available(selected) else {
      throw AgentFailure(message: "未检测到 \(selected.title)。请在设置 → 通用中选择已安装的编辑器。")
    }
    switch try EditorOpenRequest.make(editor: selected, file: file, line: line) {
    case .file(let file):
      guard NSWorkspace.shared.open(file) else { throw AgentFailure(message: "无法在默认应用中打开文件。") }
    case .command(let executable, let arguments):
      let output = try await LocalWorkspaceService.command(executable, arguments, at: root)
      guard output.status == 0 else { throw AgentFailure(message: output.text) }
    case .appURL(let url, let bundleID):
      guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
        throw AgentFailure(message: "找不到编辑器。请重新选择已安装的应用。")
      }
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init()) { _, error in
          if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
      }
    }
  }
}
