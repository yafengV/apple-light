import Foundation

extension AppearancePreferences {
  var hasAdvancedChanges: Bool {
    let defaults = Self()
    if uiSize != defaults.uiSize || codeSize != defaults.codeSize || !codeFont.isEmpty { return true }
    if reduceMotion != defaults.reduceMotion || diffMarkerStyle != defaults.diffMarkerStyle { return true }
    if usePointerCursors != defaults.usePointerCursors { return true }
    for (palette, contrast) in [(light, defaults.light.contrast), (dark, defaults.dark.contrast)] {
      if palette.contrast != contrast || !palette.translucentSidebar { return true }
      if palette.uiFace != nil || palette.codeFace != nil || palette.contentFace != nil { return true }
      if palette.codeFont?.isEmpty == false || palette.contentFont?.isEmpty == false { return true }
    }
    return false
  }

  /// Reset Advanced only. Mode, UI family, preset, colors and semantic colors
  /// belong to Visual style and must survive this action.
  func resettingAdvanced() -> Self {
    let defaults = Self()
    var value = self
    value.uiSize = defaults.uiSize
    value.codeSize = defaults.codeSize
    value.codeFont = defaults.codeFont
    value.reduceMotion = defaults.reduceMotion
    value.diffMarkerStyle = defaults.diffMarkerStyle
    value.usePointerCursors = defaults.usePointerCursors
    for dark in [false, true] {
      var palette = dark ? value.dark : value.light
      palette.uiFace = nil
      palette.contentFont = nil; palette.contentFace = nil
      palette.codeFont = nil; palette.codeFace = nil
      palette.contrast = dark ? defaults.dark.contrast : defaults.light.contrast
      palette.translucentSidebar = true
      if dark { value.dark = palette } else { value.light = palette }
    }
    return value
  }
}
