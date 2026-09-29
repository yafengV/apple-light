import AppKit

@MainActor enum AppearanceThemeClipboard {
  static func copy(_ appearance: AppearancePreferences, dark: Bool, to pasteboard: NSPasteboard) throws {
    let value = try appearance.themeShare(dark: dark).encoded()
    pasteboard.clearContents()
    guard pasteboard.setString(value, forType: .string) else { throw AgentFailure(message: "无法将主题复制到剪贴板。") }
  }
}
