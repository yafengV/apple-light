import Foundation

struct FileSelectionEditRequest: Sendable {
  static let maximumSelectionLength = 32 * 1024
  static let maximumContextLength = 128 * 1024
  static let instructions = "Rewrite only the selected text according to the user's instruction. Use the provided document excerpt only as context. Preserve the file's language, style, indentation, and line endings. Return only the replacement text, without Markdown fences or an explanation."

  let path: String
  let source: String
  let range: NSRange
  let instruction: String

  var selectedText: String? {
    guard let swiftRange = Range(range, in: source) else { return nil }
    return String(source[swiftRange])
  }

  func prompt() throws -> String {
    let parts = try promptParts()
    return parts.header + parts.appendix
  }

  func promptParts() throws -> (header: String, appendix: String) {
    let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 4_000 else {
      throw AgentFailure(message: "请用 1 至 4000 字节说明想怎样修改选中的代码。")
    }
    guard range.length > 0, range.length <= Self.maximumSelectionLength,
      let swiftRange = Range(range, in: source), let selected = selectedText,
      !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentFailure(message: "请选择不超过 32 KiB 的非空文本。")
    }
    let leading = source[..<swiftRange.lowerBound]
    let trailing = source[swiftRange.upperBound...]
    let available = max(0, Self.maximumContextLength - selected.count)
    let leadingCount = min(leading.count, available / 2)
    let trailingCount = min(trailing.count, available - leadingCount)
    let remaining = available - leadingCount - trailingCount
    let leadingExtra = min(remaining, leading.count - leadingCount)
    let trailingExtra = min(remaining - leadingExtra, trailing.count - trailingCount)
    let before = String(leading.suffix(leadingCount + leadingExtra))
    let after = String(trailing.prefix(trailingCount + trailingExtra))
    let context = before + selected + after
    let header = Self.instructions + "\n\nFile: \(path)\n\nInstruction:\n\(trimmed)"
    let appendix = "\n\n<selected_text>\n\(selected)\n</selected_text>\n\n<document_context>\n\(context)\n</document_context>"
    guard header.utf8.count <= 48_000, appendix.utf8.count <= 1_000_000 else {
      throw AgentFailure(message: "选区上下文过大，请缩小选区后重试。")
    }
    return (header, appendix)
  }

  func proposal(from output: String) throws -> FileSelectionEditProposal {
    guard (output as NSString).length <= Self.maximumSelectionLength,
      !output.contains("\0"), output != selectedText else {
      throw AgentFailure(message: "模型未返回有效的新选区内容，请重试。")
    }
    guard let swiftRange = Range(range, in: source) else {
      throw AgentFailure(message: "选区已变化，请重新选择。")
    }
    var content = source
    content.replaceSubrange(swiftRange, with: output)
    guard content.utf8.count <= LocalWorkspaceService.maximumEditableTextBytes else {
      throw AgentFailure(message: "建议修改后文件超过 1 MiB 的应用内编辑上限。")
    }
    return FileSelectionEditProposal(replacement: output, content: content)
  }
}

struct FileSelectionEditProposal: Equatable {
  let replacement: String
  let content: String

  func prefersInlineReview(selectedText: String) -> Bool {
    let original = selectedText as NSString
    let replacement = replacement as NSString
    return original.length + replacement.length <= 4_000
      && selectedText.components(separatedBy: "\n").count <= 40
      && self.replacement.components(separatedBy: "\n").count <= 40
  }
}
