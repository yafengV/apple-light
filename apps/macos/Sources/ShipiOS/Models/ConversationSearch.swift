import Foundation

struct ConversationTextID: Hashable, Sendable {
  let run: String
  let part: String
}

struct ConversationMatch: Identifiable, Equatable, Sendable {
  struct ID: Hashable, Sendable {
    let text: ConversationTextID
    let location: Int
    let length: Int
  }
  let id: ID
  var textID: ConversationTextID { id.text }
  var range: NSRange { NSRange(location: id.location, length: id.length) }
}

struct ConversationSearchInput: Equatable, Sendable {
  let run: String
  let prompt: String
  let markdown: String?
  let plain: [String: String]
  var responseItems: [ChatResponseItem]? = nil
}

enum ConversationSearch {
  static func inputs(_ runs: [AgentRun], library: WorkspaceLibrary) -> [ConversationSearchInput] {
    runs.map { run in
      var plain: [String: String] = [:]
      if run.kind != "chat" {
        plain["operation"] = run.title
        plain["summary"] = run.displaySummary
        if run.kind == "doctor", let output = run.result?["command"]["stdout"].text {
          plain["output"] = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        plain["diagnostic"] = run.result?["command"]["diagnostics"].items.first?["message"].text
      } else {
        plain["error"] = run.result?["message"].text
        if ["cancelled", "interrupted"].contains(run.status) {
          plain["stopped"] = "回复已停止，已保留收到的内容。"
        }
      }
      return ConversationSearchInput(
        run: run.id,
        prompt: library.notes[run.id].flatMap { $0.isEmpty ? nil : $0 } ?? run.title,
        markdown: run.kind == "chat" ? run.result?["response"].text ?? "" : nil,
        plain: plain, responseItems: run.kind == "chat" ? run.responseItems : nil)
    }
  }

  static func ranges(in text: String, query: String) -> [NSRange] {
    guard !query.isEmpty else { return [] }
    let text = text as NSString
    var result: [NSRange] = []
    var remaining = NSRange(location: 0, length: text.length)
    while remaining.length > 0 {
      let match = text.range(of: query, options: [.caseInsensitive], range: remaining)
      guard match.location != NSNotFound, match.length > 0 else { break }
      result.append(match)
      let next = NSMaxRange(match)
      remaining = NSRange(location: next, length: text.length - next)
    }
    return result
  }

  static func find(_ inputs: [ConversationSearchInput], query: String) -> [ConversationMatch] {
    guard !query.isEmpty else { return [] }
    return inputs.flatMap { input in
      var texts: [(String, String)] = [("prompt", input.prompt)]
      if let items = input.responseItems {
        for item in items {
          if let text = item.text {
            texts += segments(MessageDocument.parse(text), prefix: item.searchPrefix)
          }
        }
      } else if let source = input.markdown {
        texts += segments(MessageDocument.parse(source))
      }
      for part in ["operation", "summary", "output", "diagnostic", "error", "stopped"] {
        if let text = input.plain[part] { texts.append((part, text)) }
      }
      return texts.flatMap { part, text in
        ranges(in: text, query: query).map {
          ConversationMatch(
            id: .init(
              text: .init(run: input.run, part: part), location: $0.location, length: $0.length))
        }
      }
    }
  }

  static func segments(_ blocks: [MessageBlock], prefix: String = "response") -> [(String, String)] {
    blocks.flatMap { block in
      switch block.kind {
      case .paragraph, .heading:
        return [(prefix + "." + block.id, String(block.text.characters))]
      case .code:
        let displayed =
          block.source.hasSuffix("\n") ? String(block.source.dropLast()) : block.source
        return [(prefix + "." + block.id, displayed)]
      case .table:
        return block.rows.enumerated().flatMap { row, cells in
          cells.enumerated().map { column, text in
            ("\(prefix).\(block.id).cell.\(row).\(column)", String(text.characters))
          }
        }
      default: return segments(block.children, prefix: prefix)
      }
    }
  }
}
