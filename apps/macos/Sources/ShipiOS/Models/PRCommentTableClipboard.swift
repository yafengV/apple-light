import AppKit

struct PRCommentTableClipboard: Equatable {
  let markdown: String
  let html: String
  init?(block: MessageBlock) {
    guard block.kind == .table, !JavaScriptText.trimmed(block.rows.flatMap { $0 }.map { String($0.characters) }.joined()).isEmpty else { return nil }
    markdown = JavaScriptText.trimmed(block.source)
    guard !markdown.isEmpty else { return nil }
    func row(_ cells: [AttributedString], header: Bool) -> String {
      let tag = header ? "th" : "td"
      return "<tr>" + cells.map { "<\(tag)>\(Self.inlineHTML($0))</\(tag)>" }.joined() + "</tr>"
    }
    html = "<table><thead>" + row(block.rows[0], header: true) + "</thead><tbody>"
      + block.rows.dropFirst().map { row($0, header: false) }.joined() + "</tbody></table>"
  }
  func write(to pasteboard: NSPasteboard) -> Bool {
    let item = NSPasteboardItem()
    guard item.setString(markdown, forType: .string), item.setString(html, forType: .html) else { return false }
    pasteboard.clearContents(); return pasteboard.writeObjects([item])
  }
  static func inlineHTML(_ value: AttributedString) -> String {
    value.runs.map { run in
      var html = escape(String(value[run.range].characters)).replacingOccurrences(of: "\n", with: "<br>")
      let intent = run.inlinePresentationIntent ?? []
      if intent.contains(.code) { html = "<code dir=\"ltr\">\(html)</code>" }
      if intent.contains(.strikethrough) { html = "<del>\(html)</del>" }
      if intent.contains(.emphasized) { html = "<em>\(html)</em>" }
      if intent.contains(.stronglyEmphasized) { html = "<strong>\(html)</strong>" }
      if let link = run.link, ["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") {
        html = "<a href=\"\(escape(link.absoluteString))\">\(html)</a>"
      }
      return html
    }.joined()
  }
  private static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
  }
}
