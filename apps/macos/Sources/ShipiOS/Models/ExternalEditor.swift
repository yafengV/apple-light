import Foundation

enum ExternalEditor: String, CaseIterable, Identifiable {
  case system, xcode, vscode
  var id: String { rawValue }
  var title: String {
    switch self {
    case .system: "系统默认应用"
    case .xcode: "Xcode"
    case .vscode: "Visual Studio Code"
    }
  }
  var bundleID: String? {
    switch self {
    case .system: nil
    case .xcode: "com.apple.dt.Xcode"
    case .vscode: "com.microsoft.VSCode"
    }
  }
}

enum EditorOpenRequest: Equatable {
  case file(URL)
  case command(String, [String])
  case appURL(URL, bundleID: String)

  static func make(editor: ExternalEditor, file: URL, line: Int?) throws -> Self {
    guard file.isFileURL, file.path.hasPrefix("/"), line == nil || line! > 0 else {
      throw AgentFailure(message: "文件路径或行号无效。")
    }
    switch editor {
    case .system:
      guard line == nil else {
        throw AgentFailure(message: "此默认应用不支持行定位。请在设置 → 通用中选择 Xcode 或 Visual Studio Code。")
      }
      return .file(file)
    case .xcode:
      return .command(
        "/usr/bin/xcrun", ["xed"] + (line.map { ["--line", String($0)] } ?? []) + [file.path])
    case .vscode:
      var url = URLComponents()
      url.scheme = "vscode"
      url.host = "file"
      url.path = file.path + (line.map { ":\($0):1" } ?? "")
      guard let target = url.url else { throw AgentFailure(message: "无法生成编辑器地址。") }
      return .appURL(target, bundleID: "com.microsoft.VSCode")
    }
  }
}
