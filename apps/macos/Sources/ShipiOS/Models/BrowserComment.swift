import Foundation

struct BrowserSelectionRect: Codable, Equatable, Sendable {
  let x: Double
  let y: Double
  let width: Double
  let height: Double
}

struct BrowserComment: Codable, Equatable, Identifiable, Sendable {
  var id = UUID()
  let reference: BrowserElementReference
  var body: String
  var styleFeedback: BrowserStyleFeedback? = nil
}

struct BrowserStyleFeedback: Codable, Equatable, Sendable {
  var replacementText: String? = nil
  var fontFamily: String? = nil
  var fontSize: Int? = nil
  var padding: Int? = nil
  var letterSpacing: Int? = nil
  var textColor: String? = nil
  var backgroundColor: String? = nil

  var isEmpty: Bool {
    replacementText == nil && fontFamily == nil && fontSize == nil && padding == nil
      && letterSpacing == nil && textColor == nil && backgroundColor == nil
  }

  var previewValues: [String: String] {
    var values: [String: String] = [:]
    if let replacementText { values["text"] = replacementText }
    if let fontFamily { values["fontFamily"] = fontFamily }
    if let fontSize { values["fontSize"] = "\(fontSize)px" }
    if let padding { values["padding"] = "\(padding)px" }
    if let letterSpacing { values["letterSpacing"] = "\(letterSpacing)px" }
    if let textColor { values["textColor"] = textColor }
    if let backgroundColor { values["backgroundColor"] = backgroundColor }
    return values
  }

  var summary: String {
    var parts: [String] = []
    if let replacementText { parts.append("文字：\(replacementText)") }
    if let fontFamily { parts.append("字体：\(fontFamily)") }
    if let fontSize { parts.append("字号：\(fontSize)px") }
    if let padding { parts.append("内边距：\(padding)px") }
    if let letterSpacing { parts.append("字距：\(letterSpacing)px") }
    if let textColor { parts.append("文字颜色：\(textColor)") }
    if let backgroundColor { parts.append("背景颜色：\(backgroundColor)") }
    return parts.joined(separator: " · ")
  }
}
