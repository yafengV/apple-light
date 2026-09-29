import AppKit

@MainActor enum AppearanceFontCatalog {
  struct Face: Equatable { let value: AppearanceFontFace; let style: String; let weight: Int; let italic: Bool; let monospaced: Bool }
  struct Family { let name: String; let faces: [Face] }
  static let families: [Family] = NSFontManager.shared.availableFontFamilies.sorted {
    $0.localizedStandardCompare($1) == .orderedAscending
  }.compactMap { family in
    let defaultName = (NSFont(name: family, size: 13) ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13))?.fontName
    let faces = (NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []).compactMap { member -> Face? in
      guard member.count >= 4, let name = member[0] as? String, let style = member[1] as? String,
        let weight = member[2] as? NSNumber, let traits = member[3] as? NSNumber, let font = NSFont(name: name, size: 13) else { return nil }
      return Face(value: .init(family: family, fullName: font.displayName ?? name, postscriptName: name),
        style: style, weight: weight.intValue, italic: NSFontTraitMask(rawValue: traits.uintValue).contains(.italicFontMask), monospaced: font.isFixedPitch)
    }.sorted { a, b in
      if (a.value.postscriptName == defaultName) != (b.value.postscriptName == defaultName) { return a.value.postscriptName == defaultName }
      return a.weight != b.weight ? a.weight < b.weight : a.italic != b.italic ? !a.italic : a.style.localizedStandardCompare(b.style) == .orderedAscending
    }
    return faces.isEmpty ? nil : Family(name: family, faces: faces)
  }
  static func options(code: Bool) -> [Family] { code ? families.filter { $0.faces.allSatisfy(\.monospaced) } : families }
  static func family(_ value: String, code: Bool) -> Family? {
    for name in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }) {
      if let found = options(code: code).first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return found }
    }
    return nil
  }
  static func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
}
