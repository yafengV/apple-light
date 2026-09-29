import AppKit
import Observation

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
  static func family(_ value: String) -> Family? { resolve(value, families: families)?.family }
  static func resolve(_ value: String?, face: AppearanceFontFace? = nil, families: [Family]?) -> (family: Family, face: Face)? {
    guard let name = AppearanceFontFamily.first(value),
      let family = families?.first(where: { $0.name.lowercased() == name.lowercased() }), let first = family.faces.first else { return nil }
    let selected = face?.family.lowercased() == family.name.lowercased()
      ? family.faces.first(where: { $0.value.postscriptName == face?.postscriptName }) : nil
    return (family, selected ?? first)
  }
  static func quote(_ value: String) -> String { AppearanceFontFamily.quote(value) }
}

@MainActor struct AppearanceFontSelection {
  let resolved: (family: AppearanceFontCatalog.Family, face: AppearanceFontCatalog.Face)?
  let name: String?
  let title: String
  let styleEnabled: Bool
  var selectedDefault: Bool { name == nil }
  init(value: String?, face: AppearanceFontFace?, role: AppearanceFontRole, families: [AppearanceFontCatalog.Family]?) {
    resolved = AppearanceFontCatalog.resolve(value, face: face, families: families)
    name = resolved?.family.name ?? AppearanceFontFamily.displayName(value) ?? (role == .content ? value : nil)
    title = name ?? role.defaultTitle
    styleEnabled = families?.isEmpty == false && resolved != nil
      && (role != .code || resolved?.family.faces.allSatisfy(\.monospaced) == true)
  }
}

/// The query is shared and cached for this process; an empty/unavailable directory
/// offers the same custom-value fallback as the reference application.
@MainActor @Observable final class AppearanceFontCatalogSource {
  static let shared = AppearanceFontCatalogSource()
  private(set) var loaded = false
  private(set) var families: [AppearanceFontCatalog.Family]?
  private var loading = false
  init() {}
  init(families: [AppearanceFontCatalog.Family]?) { self.families = families; loaded = true }
  func load() async {
    guard !loaded, !loading else { return }; loading = true
    await Task.yield()
    families = AppearanceFontCatalog.families; loaded = true; loading = false
  }
}
