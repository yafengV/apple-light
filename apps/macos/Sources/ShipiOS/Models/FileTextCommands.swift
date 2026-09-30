import Foundation

enum FileTextCommand: Equatable {
  case insertIndent, indentLines, outdentLines, toggleLineComment, toggleBlockComment
  case moveUp, moveDown, copyUp, copyDown, insertBlankLine
}

struct FileTextEdit: Equatable {
  let range: NSRange
  let replacement: String
  let selection: NSRange
}

enum FileTextCommands {
  private static let indent = "  "

  private struct Line {
    let start: Int
    let end: Int
    let content: String
    let ending: String
    var text: String { content + ending }
  }

  private struct Mutation {
    let location: Int
    let removed: Int
    let inserted: String
    var delta: Int { (inserted as NSString).length - removed }
  }

  static func edit(_ command: FileTextCommand, in source: String,
    selection: NSRange, path: String) -> FileTextEdit? {
    let ns = source as NSString
    guard selection.location >= 0, NSMaxRange(selection) <= ns.length else { return nil }
    let lines = splitLines(source)
    let first = lineIndex(at: selection.location, lines: lines)
    let endLocation = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
    let last = lineIndex(at: endLocation, lines: lines)
    switch command {
    case .insertIndent:
      if selection.length == 0 {
        let beforeCaret = ns.substring(with: NSRange(location: lines[first].start,
          length: selection.location - lines[first].start))
        var column = 0
        for character in beforeCaret {
          column += character == "\t" ? 2 - column % 2 : 1
        }
        let spaces = String(repeating: " ", count: 2 - column % 2)
        return .init(range: selection, replacement: spaces,
          selection: NSRange(location: selection.location + (spaces as NSString).length, length: 0))
      }
      return prefixEdit(lines: lines, first: first, last: last, source: source,
        selection: selection, kind: .indent)
    case .indentLines:
      return prefixEdit(lines: lines, first: first, last: last, source: source,
        selection: selection, kind: .indent)
    case .outdentLines:
      return prefixEdit(lines: lines, first: first, last: last, source: source,
        selection: selection, kind: .outdent)
    case .toggleLineComment:
      guard let prefix = lineCommentPrefix(path) else {
        let target = selection.length == 0
          ? NSRange(location: lines[first].start, length: (lines[first].content as NSString).length)
          : selection
        return blockComment(source: source, selection: target, path: path)
      }
      return prefixEdit(lines: lines, first: first, last: last, source: source,
        selection: selection, kind: .comment(prefix))
    case .toggleBlockComment:
      return blockComment(source: source, selection: selection, path: path)
    case .moveUp, .moveDown:
      return moveLines(command, lines: lines, first: first, last: last, selection: selection)
    case .copyUp, .copyDown:
      return copyLines(command, lines: lines, first: first, last: last, selection: selection)
    case .insertBlankLine:
      let line = lines[first]
      let ending = preferredEnding(lines)
      let caret = line.end + (line.ending.isEmpty ? (ending as NSString).length : 0)
      return .init(range: NSRange(location: line.end, length: 0), replacement: ending,
        selection: NSRange(location: caret, length: 0))
    }
  }

  private static func splitLines(_ source: String) -> [Line] {
    let ns = source as NSString
    var lines: [Line] = []
    var offset = 0
    while offset < ns.length {
      let range = ns.lineRange(for: NSRange(location: offset, length: 0))
      guard NSMaxRange(range) > offset else { break }
      let raw = ns.substring(with: range)
      let ending = raw.hasSuffix("\r\n") ? "\r\n" : raw.hasSuffix("\n") ? "\n" : raw.hasSuffix("\r") ? "\r" : ""
      let contentLength = (raw as NSString).length - (ending as NSString).length
      lines.append(.init(start: offset, end: NSMaxRange(range),
        content: (raw as NSString).substring(to: contentLength), ending: ending))
      offset = NSMaxRange(range)
    }
    if lines.isEmpty || !lines[lines.count - 1].ending.isEmpty {
      lines.append(.init(start: ns.length, end: ns.length, content: "", ending: ""))
    }
    return lines
  }

  private static func lineIndex(at location: Int, lines: [Line]) -> Int {
    lines.lastIndex(where: { $0.start <= location }) ?? 0
  }

  private static func preferredEnding(_ lines: [Line]) -> String {
    lines.first(where: { !$0.ending.isEmpty })?.ending ?? "\n"
  }

  private enum PrefixKind { case indent, outdent, comment(String) }

  private static func prefixEdit(lines: [Line], first: Int, last: Int, source: String,
    selection: NSRange, kind: PrefixKind) -> FileTextEdit? {
    let relevant = Array(lines[first...last])
    let uncomment: Bool
    if case .comment(let prefix) = kind {
      let nonblank = relevant.filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      uncomment = !nonblank.isEmpty && nonblank.allSatisfy {
        let content = $0.content as NSString
        let leading = indentationLength(content)
        return content.substring(from: leading).hasPrefix(prefix)
      }
    } else { uncomment = false }
    var mutations: [Mutation] = []
    for line in relevant {
      let content = line.content as NSString
      let leading = indentationLength(content)
      switch kind {
      case .indent:
        mutations.append(.init(location: line.start, removed: 0, inserted: indent))
      case .outdent:
        let removed = leading > 0 && content.character(at: 0) == 9 ? 1 : min(2, leading)
        if removed > 0 { mutations.append(.init(location: line.start, removed: removed, inserted: "")) }
      case .comment(let prefix):
        guard leading < content.length else { continue }
        let location = line.start + leading
        if uncomment {
          var removed = (prefix as NSString).length
          if leading + removed < content.length && content.character(at: leading + removed) == 32 {
            removed += 1
          }
          mutations.append(.init(location: location, removed: removed, inserted: ""))
        } else {
          mutations.append(.init(location: location, removed: 0, inserted: prefix + " "))
        }
      }
    }
    guard !mutations.isEmpty else { return nil }
    let span = NSRange(location: lines[first].start,
      length: lines[last].end - lines[first].start)
    var replacement = (source as NSString).substring(with: span) as NSString
    for change in mutations.reversed() {
      replacement = replacement.replacingCharacters(
        in: NSRange(location: change.location - span.location, length: change.removed),
        with: change.inserted) as NSString
    }
    let start = mapped(selection.location, mutations: mutations)
    let end = mapped(NSMaxRange(selection), mutations: mutations)
    return .init(range: span, replacement: replacement as String,
      selection: NSRange(location: start, length: max(0, end - start)))
  }

  private static func indentationLength(_ content: NSString) -> Int {
    var index = 0
    while index < content.length && (content.character(at: index) == 9 || content.character(at: index) == 32) {
      index += 1
    }
    return index
  }

  private static func mapped(_ position: Int, mutations: [Mutation]) -> Int {
    var shift = 0
    for change in mutations {
      if position < change.location { break }
      if position <= change.location + change.removed {
        return change.location + shift + (change.inserted as NSString).length
      }
      shift += change.delta
    }
    return position + shift
  }

  private static func blockComment(source: String, selection: NSRange, path: String) -> FileTextEdit? {
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    let open: String
    if ["html", "htm", "md", "markdown", "xml", "svg"].contains(ext) { open = "<!--" }
    else if ["swift", "rs", "js", "jsx", "ts", "tsx", "c", "h", "cpp", "hpp", "java", "kt", "go", "css", "scss", "sql"].contains(ext) {
      open = "/*"
    } else { return nil }
    let close = open == "<!--" ? "-->" : "*/"
    let ns = source as NSString
    let original = ns.substring(with: selection)
    let openLength = (open as NSString).length, closeLength = (close as NSString).length
    if selection.location >= openLength, NSMaxRange(selection) + closeLength <= ns.length,
      ns.substring(with: NSRange(location: selection.location - openLength, length: openLength)) == open,
      ns.substring(with: NSRange(location: NSMaxRange(selection), length: closeLength)) == close {
      return .init(range: NSRange(location: selection.location - openLength,
        length: selection.length + openLength + closeLength), replacement: original,
        selection: NSRange(location: selection.location - openLength, length: selection.length))
    }
    if original.hasPrefix(open), original.hasSuffix(close),
      (original as NSString).length >= openLength + closeLength {
      let range = NSRange(location: openLength,
        length: (original as NSString).length - openLength - closeLength)
      let inner = (original as NSString).substring(with: range)
      return .init(range: selection, replacement: inner,
        selection: NSRange(location: selection.location, length: (inner as NSString).length))
    }
    let replacement = selection.length == 0 ? open + "  " + close : open + original + close
    let newSelection = selection.length == 0
      ? NSRange(location: selection.location + (open as NSString).length + 1, length: 0)
      : NSRange(location: selection.location + (open as NSString).length, length: selection.length)
    return .init(range: selection, replacement: replacement, selection: newSelection)
  }

  private static func moveLines(_ command: FileTextCommand, lines: [Line],
    first: Int, last: Int, selection: NSRange) -> FileTextEdit? {
    let upward = command == .moveUp
    guard upward ? first > 0 : last + 1 < lines.count else { return nil }
    let lower = upward ? first - 1 : first
    let upper = upward ? last : last + 1
    let segment = Array(lines[lower...upper])
    var contents = segment.map(\.content)
    if upward { contents = Array(contents.dropFirst()) + [contents[0]] }
    else { contents = [contents[contents.count - 1]] + Array(contents.dropLast()) }
    let replacement = zip(contents, segment.map(\.ending)).map { $0.0 + $0.1 }.joined()
    let oldBlockStart = lines[first].start
    let newBlockStart = upward ? lines[lower].start :
      lines[first].start + (contents[0] as NSString).length + (segment[0].ending as NSString).length
    let movedRange = upward ? 0..<(segment.count - 1) : 1..<segment.count
    let movedLength = movedRange.reduce(0) { partial, index in
      partial + (contents[index] as NSString).length + (segment[index].ending as NSString).length
    }
    let startOffset = min(selection.location - oldBlockStart, movedLength)
    let endOffset = min(NSMaxRange(selection) - oldBlockStart, movedLength)
    return .init(range: NSRange(location: lines[lower].start,
      length: lines[upper].end - lines[lower].start), replacement: replacement,
      selection: NSRange(location: newBlockStart + startOffset,
        length: max(0, endOffset - startOffset)))
  }

  private static func copyLines(_ command: FileTextCommand, lines: [Line],
    first: Int, last: Int, selection: NSRange) -> FileTextEdit {
    let block = Array(lines[first...last])
    let oldBlockStart = lines[first].start
    let blockText = block.map(\.text).joined()
    let ending = preferredEnding(lines)
    let upward = command == .copyUp
    let insertion = upward ? oldBlockStart : lines[last].end
    let prefix = !upward && block.last?.ending.isEmpty == true ? ending : ""
    let duplicate = upward && block.last?.ending.isEmpty == true ? blockText + ending : blockText
    let duplicateStart = insertion + (prefix as NSString).length
    let startOffset = selection.location - oldBlockStart
    return .init(range: NSRange(location: insertion, length: 0), replacement: prefix + duplicate,
      selection: NSRange(location: duplicateStart + startOffset, length: selection.length))
  }

  private static func lineCommentPrefix(_ path: String) -> String? {
    switch URL(fileURLWithPath: path).pathExtension.lowercased() {
    case "swift", "rs", "js", "jsx", "ts", "tsx", "c", "h", "cpp", "hpp", "java", "kt", "go", "scss":
      return "//"
    case "py", "rb", "sh", "bash", "zsh", "yaml", "yml", "toml", "pl", "r": return "#"
    case "sql", "lua": return "--"
    default: return nil
    }
  }
}
