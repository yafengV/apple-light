import Foundation
import Darwin

enum InitCommand {
  static let token = "/init"
  static let prompt = """
    Generate a file named AGENTS.md that serves as a contributor guide for this repository.
    Before writing, check whether AGENTS.md already exists in the current working directory. If it does, do not overwrite or modify it.
    Make the guide concise, specific to this repository, and easy for contributors to follow. Use the title "Repository Guidelines" and Markdown headings. Aim for 200–400 words.

    Cover the project structure, where source code and tests live, build and test commands, coding style, test conventions, and commit or pull request expectations when the repository provides evidence for them. Include concrete commands and paths where useful. Omit sections that do not apply, and do not invent requirements or secrets.
    """

  static func preparedPrompt(project: String, protocol apiProtocol: ModelAPIProtocol,
    hasAttachmentsOrComments: Bool, isSideChat: Bool = false) throws -> String {
    guard !isSideChat, project.hasPrefix("/") else {
      throw AgentFailure(message: "/init 需要可写的项目任务；请先选择项目。")
    }
    guard apiProtocol == .codexResponses else {
      throw AgentFailure(message: "/init 需要在设置 → 模型与 API 中选择 Codex Core · Responses。")
    }
    guard !hasAttachmentsOrComments else {
      throw AgentFailure(message: "请先发送或移除草稿附件和评论，再运行 /init。")
    }
    let root = URL(fileURLWithPath: project, isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue else {
      throw AgentFailure(message: "项目目录不可用，无法创建 AGENTS.md。")
    }
    let guide = root.appendingPathComponent("AGENTS.md")
    var metadata = stat()
    guard lstat(guide.path, &metadata) != 0 else {
      throw AgentFailure(message: "项目根目录已有 AGENTS.md；/init 不会覆盖它。")
    }
    guard errno == ENOENT else {
      throw AgentFailure(message: "无法检查项目根目录的 AGENTS.md。")
    }
    return prompt
  }
}
