import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PetKind: String, Codable, CaseIterable, Identifiable {
  case codey, mini, custom
  var id: String { rawValue }
  var title: String {
    switch self {
    case .codey: "Codey"
    case .mini: "Mini"
    case .custom: "自定义"
    }
  }
}

struct PetPreferences: Codable, Equatable {
  var selected: PetKind = .codey
  var visible = false
  var scale = 1.0
  var originX: Double?
  var originY: Double?
  var hasCustomPet = false
  var customName = ""

  func validated(customAssetExists: Bool? = nil) throws -> Self {
    var value = self
    value.scale = min(max(value.scale, 0.6), 1.6)
    value.customName = value.customName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.customName.utf8.count <= 120 else {
      throw AgentFailure(message: "宠物名称不能超过 120 字节。")
    }
    if let customAssetExists, value.hasCustomPet, !customAssetExists {
      throw AgentFailure(message: "自定义宠物文件缺失。")
    }
    if value.selected == .custom, !value.hasCustomPet {
      throw AgentFailure(message: "请先导入自定义宠物。")
    }
    return value
  }

  enum CodingKeys: String, CodingKey {
    case selected, visible, scale, originX, originY, hasCustomPet, customName
  }
  init() {}
  init(
    selected: PetKind = .codey, visible: Bool = false, scale: Double = 1,
    originX: Double? = nil, originY: Double? = nil, hasCustomPet: Bool = false,
    customName: String = ""
  ) {
    self.selected = selected
    self.visible = visible
    self.scale = scale
    self.originX = originX
    self.originY = originY
    self.hasCustomPet = hasCustomPet
    self.customName = customName
  }
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    selected = try container.decodeIfPresent(PetKind.self, forKey: .selected) ?? .codey
    visible = try container.decodeIfPresent(Bool.self, forKey: .visible) ?? false
    scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1
    originX = try container.decodeIfPresent(Double.self, forKey: .originX)
    originY = try container.decodeIfPresent(Double.self, forKey: .originY)
    hasCustomPet = try container.decodeIfPresent(Bool.self, forKey: .hasCustomPet) ?? false
    customName = try container.decodeIfPresent(String.self, forKey: .customName) ?? ""
  }
}

enum PetActivityStatus: String, Equatable {
  case idle, running, ready, needsInput, blocked
  var title: String {
    switch self {
    case .idle: "空闲"
    case .running: "正在运行"
    case .ready: "有未读活动"
    case .needsInput: "等待操作"
    case .blocked: "任务失败"
    }
  }
  var color: NSColor {
    switch self {
    case .idle: .secondaryLabelColor
    case .running: .systemBlue
    case .ready: .systemGreen
    case .needsInput: .systemOrange
    case .blocked: .systemOrange
    }
  }
  var atlasRow: Int {
    switch self {
    case .idle: 0
    case .running: 7
    case .ready: 3
    case .needsInput: 5
    case .blocked: 5
    }
  }
}

enum PetStorage {
  static let preferencesName = "pet.json"
  static let customAssetName = "custom-pet.asset"
  static let maximumAssetBytes = 20 * 1_024 * 1_024
  static let supportedSizes = [(1_536, 1_872), (1_536, 2_288)]

  static func preferencesURL(root: URL) -> URL { root.appendingPathComponent(preferencesName) }
  static func customAssetURL(root: URL) -> URL { root.appendingPathComponent(customAssetName) }

  static func load(root: URL) throws -> (PetPreferences, Data?) {
    let preferencesURL = preferencesURL(root: root)
    guard FileManager.default.fileExists(atPath: preferencesURL.path) else {
      return (PetPreferences(), nil)
    }
    let assetURL = customAssetURL(root: root)
    let assetExists = FileManager.default.fileExists(atPath: assetURL.path)
    let preferences = try JSONDecoder().decode(
      PetPreferences.self, from: Data(contentsOf: preferencesURL)
    ).validated(customAssetExists: assetExists)
    let data = preferences.hasCustomPet
      ? try Data(contentsOf: assetURL, options: .mappedIfSafe) : nil
    if let data { _ = try validateAsset(data) }
    return (preferences, data)
  }

  static func save(_ preferences: PetPreferences, root: URL) throws {
    let assetExists = FileManager.default.fileExists(atPath: customAssetURL(root: root).path)
    let preferences = try preferences.validated(customAssetExists: assetExists)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = preferencesURL(root: root)
    try JSONEncoder().encode(preferences).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  static func validateAsset(_ data: Data) throws -> NSSize {
    guard data.count <= maximumAssetBytes,
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let type = CGImageSourceGetType(source) as String?,
      type == UTType.png.identifier || type == UTType.webP.identifier,
      CGImageSourceGetCount(source) > 0,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      supportedSizes.contains(where: { $0.0 == width && $0.1 == height }),
      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
      cgImage.alphaInfo != .none, cgImage.alphaInfo != .noneSkipFirst,
      cgImage.alphaInfo != .noneSkipLast,
      NSImage(data: data) != nil
    else {
      throw AgentFailure(message: "宠物须为透明 PNG 或 WebP、1536 × 1872 或 1536 × 2288，且不超过 20 MiB。")
    }
    return NSSize(width: width, height: height)
  }
}

enum PetAtlas {
  static let columns = 8
  static let cellSize = NSSize(width: 192, height: 208)

  static func frame(image: NSImage, row: Int, column: Int) -> NSImage? {
    guard row >= 0, column >= 0, column < columns,
      let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      source.width == 1_536, source.height == 1_872 || source.height == 2_288,
      row < source.height / Int(cellSize.height)
    else { return nil }
    let rect = CGRect(
      x: column * Int(cellSize.width),
      y: source.height - (row + 1) * Int(cellSize.height),
      width: Int(cellSize.width), height: Int(cellSize.height))
    guard let cropped = source.cropping(to: rect) else { return nil }
    return NSImage(cgImage: cropped, size: cellSize)
  }
}
