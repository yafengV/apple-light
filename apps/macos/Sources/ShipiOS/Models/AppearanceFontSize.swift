import Foundation

enum AppearanceFontSize: String, Codable, CaseIterable, Sendable {
  case ui, content, code
  var title: String {
    switch self { case .ui: "界面字号"; case .content: "内容字体大小"; case .code: "代码字号" }
  }
  var description: String {
    switch self {
    case .ui: "调整 ShipiOS 界面的基础字号。"
    case .content: "调整页面内容的基础字号。"
    case .code: "调整聊天和差异中代码的基础字号。"
    }
  }
  var range: ClosedRange<Double> { self == .ui ? 11...16 : 8...24 }
  var defaultValue: Double { self == .code ? 12 : 14 }
  var searchField: SettingsSearchField {
    switch self { case .ui: .uiFontSize; case .content: .contentFontSize; case .code: .codeFontSize }
  }
  func value(in appearance: AppearancePreferences) -> Double {
    switch self { case .ui: appearance.uiSize; case .content: appearance.contentSize; case .code: appearance.codeSize }
  }
  func setting(_ value: Double, in appearance: inout AppearancePreferences) {
    switch self { case .ui: appearance.uiSize = value; case .content: appearance.contentSize = value; case .code: appearance.codeSize = value }
  }
  func normalized(_ value: Double) -> Double { value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : defaultValue }
  /// HTML number inputs sanitize their value before the reference blur/Enter parser reads it.
  func parsed(_ text: String) -> Double? {
    guard text.range(of: #"^-?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil,
      let value = Double(text), value.isFinite else { return nil }
    return value
  }
  func committed(_ text: String, current: Double) -> Double {
    guard let value = parsed(text), range.contains(value) else { return current }; return value
  }
  /// step=1 is anchored to the integer minimum; fractional values move to the next grid point.
  func stepped(_ text: String, direction: Int) -> String {
    guard let value = parsed(text) else { return Self.text(range.lowerBound) }
    if direction > 0, value >= range.upperBound { return text }
    if direction < 0, value <= range.lowerBound { return text }
    if direction > 0, value < range.lowerBound { return Self.text(range.lowerBound) }
    if direction < 0, value > range.upperBound { return Self.text(range.upperBound) }
    // Blink's real-number step grid accepts an error of step / 2^24.
    let decimal = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) ?? Decimal(value)
    var remainder = decimal - Decimal(value.rounded())
    if remainder < 0 { remainder = -remainder }
    let onGrid = remainder <= Decimal(1) / Decimal(16_777_216)
    let next = onGrid ? value.rounded() + Double(direction) : direction > 0 ? ceil(value) : floor(value)
    return Self.text(normalized(next))
  }
  static func text(_ value: Double) -> String {
    let text = String(value)
    return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
  }
}
