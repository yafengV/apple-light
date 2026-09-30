import AppKit
import Observation

struct FileFindOptions: Equatable, Sendable {
  var matchCase = false
  var wholeWord = false
  var regularExpression = false
}

struct FileFindResult: Sendable {
  let ranges: [NSRange]
  let error: String?
}

enum FileFindEngine {
  static let maximumMatches = 10_000

  static func expression(for query: String, options: FileFindOptions) throws -> NSRegularExpression {
    let body = options.regularExpression ? query : NSRegularExpression.escapedPattern(for: query)
    let pattern = options.wholeWord
      ? "(?<![\\p{L}\\p{M}\\p{N}_])(?:\(body))(?![\\p{L}\\p{M}\\p{N}_])" : body
    return try NSRegularExpression(pattern: pattern,
      options: options.matchCase ? [] : [.caseInsensitive])
  }

  static func find(_ query: String, in source: String, options: FileFindOptions) -> FileFindResult {
    guard !query.isEmpty else { return .init(ranges: [], error: nil) }
    do {
      let expression = try expression(for: query, options: options)
      let fullRange = NSRange(location: 0, length: (source as NSString).length)
      var ranges: [NSRange] = []
      expression.enumerateMatches(in: source, range: fullRange) { match, _, stop in
        if Task<Never, Never>.isCancelled { stop.pointee = true; return }
        if let match, match.range.length > 0 { ranges.append(match.range) }
        if ranges.count == maximumMatches { stop.pointee = true }
      }
      return .init(ranges: ranges, error: nil)
    } catch { return .init(ranges: [], error: "正则表达式无效：\(error.localizedDescription)") }
  }

  static func replacing(_ range: NSRange, in source: String, query: String,
    with replacement: String, options: FileFindOptions) -> String? {
    guard NSMaxRange(range) <= (source as NSString).length else { return nil }
    guard let expression = try? expression(for: query, options: options) else { return nil }
    let fullRange = NSRange(location: 0, length: (source as NSString).length)
    var selected: NSTextCheckingResult?
    expression.enumerateMatches(in: source, range: fullRange) { match, _, stop in
      guard let match else { return }
      if match.range == range { selected = match; stop.pointee = true }
      else if match.range.location > range.location { stop.pointee = true }
    }
    guard let match = selected else { return nil }
    return options.regularExpression
      ? expression.replacementString(for: match, in: source, offset: 0, template: replacement)
      : replacement
  }

  static func replacingAll(in source: String, query: String,
    with replacement: String, options: FileFindOptions) -> String? {
    guard !query.isEmpty, let expression = try? expression(for: query, options: options) else { return nil }
    let fullRange = NSRange(location: 0, length: (source as NSString).length)
    let matches = expression.matches(in: source, range: fullRange).filter { $0.range.length > 0 }
    guard !matches.isEmpty else { return nil }
    var result = source as NSString
    for match in matches.reversed() {
      let value = options.regularExpression
        ? expression.replacementString(for: match, in: source, offset: 0, template: replacement)
        : replacement
      result = result.replacingCharacters(in: match.range, with: value) as NSString
    }
    return result as String
  }
}

@MainActor @Observable
final class FileFindSession {
  var isPresented = false
  var isReplacing = false
  var query = ""
  var replacement = ""
  var options = FileFindOptions()
  private(set) var matches: [NSRange] = []
  private(set) var selectedIndex: Int?
  private(set) var error: String?
  var focusRequest = UUID()
  @ObservationIgnored weak var editor: FilePreviewTextView?
  @ObservationIgnored private var searchTask: Task<Void, Never>?
  @ObservationIgnored private var searchToken = UUID()

  var countLabel: String {
    guard !matches.isEmpty else { return "0 个结果" }
    return "\((selectedIndex ?? 0) + 1)/\(matches.count)"
  }

  func bind(editor: FilePreviewTextView?) {
    guard self.editor !== editor else { return }
    clearHighlights()
    self.editor = editor
    updateHighlights()
  }

  func open(editor: FilePreviewTextView?, replacing: Bool = false, source: String) {
    bind(editor: editor)
    if let editor {
      let range = editor.selectedRange()
      if range.length > 0 && range.length <= 200, NSMaxRange(range) <= (editor.string as NSString).length {
        let selection = (editor.string as NSString).substring(with: range)
        if !selection.contains("\n") { query = selection }
      }
    }
    isPresented = true
    if replacing { isReplacing = true }
    focusRequest = UUID()
    refresh(in: source, reveal: true)
  }

  func close() {
    isPresented = false
    searchTask?.cancel()
    searchTask = nil
    searchToken = UUID()
    clearHighlights()
  }

  func refresh(in source: String, reveal: Bool = false) {
    searchTask?.cancel()
    clearHighlights()
    let token = UUID()
    searchToken = token
    guard isPresented, !query.isEmpty else {
      matches = []; selectedIndex = nil; error = nil
      return
    }
    let query = query, options = options
    searchTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(100))
      guard !Task.isCancelled else { return }
      let search = Task.detached(priority: .userInitiated) {
        FileFindEngine.find(query, in: source, options: options)
      }
      let result = await withTaskCancellationHandler { await search.value } onCancel: { search.cancel() }
      guard !Task.isCancelled, let self, self.searchToken == token else { return }
      let oldRange = self.selectedIndex.flatMap { self.matches.indices.contains($0) ? self.matches[$0] : nil }
      self.matches = result.ranges
      self.error = result.error
      self.selectedIndex = result.ranges.isEmpty ? nil :
        (oldRange.flatMap { result.ranges.firstIndex(of: $0) } ?? 0)
      self.updateHighlights()
      if reveal { self.revealSelectedMatch() }
    }
  }

  func move(_ offset: Int) {
    guard !matches.isEmpty else { return }
    let current = selectedIndex ?? (offset > 0 ? -1 : 0)
    selectedIndex = ((current + offset) % matches.count + matches.count) % matches.count
    updateHighlights()
    revealSelectedMatch()
  }

  private func clearHighlights() {
    guard let editor, let layout = editor.layoutManager else { return }
    layout.removeTemporaryAttribute(.backgroundColor,
      forCharacterRange: NSRange(location: 0, length: (editor.string as NSString).length))
  }

  private func updateHighlights() {
    clearHighlights()
    guard isPresented, let editor, let layout = editor.layoutManager else { return }
    let length = (editor.string as NSString).length
    for (index, range) in matches.enumerated() where NSMaxRange(range) <= length {
      let opacity: CGFloat = index == selectedIndex ? 0.42 : 0.22
      layout.addTemporaryAttribute(.backgroundColor,
        value: NSColor.controlAccentColor.withAlphaComponent(opacity), forCharacterRange: range)
    }
  }

  private func revealSelectedMatch() {
    guard let selectedIndex, matches.indices.contains(selectedIndex), let editor else { return }
    let range = matches[selectedIndex]
    guard NSMaxRange(range) <= (editor.string as NSString).length else { return }
    editor.setSelectedRange(range)
    editor.scrollRangeToVisible(range)
  }

  func replaceCurrent() {
    guard let editor, editor.isEditable, let selectedIndex, matches.indices.contains(selectedIndex),
      let value = FileFindEngine.replacing(matches[selectedIndex], in: editor.string,
        query: query, with: replacement, options: options) else { return }
    editor.insertText(value, replacementRange: matches[selectedIndex])
    refresh(in: editor.string, reveal: true)
  }

  func replaceAll() {
    guard let editor, editor.isEditable,
      let updated = FileFindEngine.replacingAll(in: editor.string, query: query,
        with: replacement, options: options) else { return }
    let range = NSRange(location: 0, length: (editor.string as NSString).length)
    editor.insertText(updated, replacementRange: range)
    refresh(in: editor.string)
  }
}
