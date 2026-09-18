import AppKit
import Foundation

struct ProfilePreferences: Codable, Equatable {
  var displayName = ""
  var username = ""
  var hasAvatar = false

  func validated() throws -> Self {
    var value = self
    value.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    value.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.displayName.utf8.count <= 160 else {
      throw AgentFailure(message: "显示名称不能超过 160 字节。")
    }
    guard value.username.utf8.count <= 60 else {
      throw AgentFailure(message: "用户名不能超过 60 字节。")
    }
    if !value.username.isEmpty {
      let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
      guard value.username.unicodeScalars.allSatisfy(allowed.contains) else {
        throw AgentFailure(message: "用户名只能包含字母、数字、句点、下划线和连字符。")
      }
    }
    return value
  }

  var initials: String {
    let source = displayName.isEmpty ? (username.isEmpty ? "S" : username) : displayName
    return source.split(whereSeparator: { $0.isWhitespace }).prefix(2)
      .compactMap(\.first).map(String.init).joined().uppercased()
  }
}

struct ProfileActivity: Equatable {
  let lifetimeTokens: Int
  let peakTokens: Int
  let activeStreak: Int
  let taskCount: Int
  let turnCount: Int
  let longestTaskTitle: String?
  let longestTaskDuration: TimeInterval
}

extension WorkspaceLibrary {
  func profileActivity(now: Date = Date(), calendar: Calendar = .current) -> ProfileActivity {
    let records = modelUsageRecords
    let runsByID = Dictionary(localRuns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let longest = tasks.compactMap { task -> (String, TimeInterval)? in
      let runs = task.runIDs.compactMap { runsByID[$0] }
      guard let start = runs.map(\.createdAt).min(), let end = runs.map(\.updatedAt).max() else {
        return nil
      }
      return (task.title, max(0, (end - start) / 1_000))
    }.max { $0.1 < $1.1 }

    let activeDays = Set(localRuns.map { calendar.startOfDay(for: $0.date) })
    let latestStart = activeDays.max()
    var streak = 0
    if let latestStart {
      let today = calendar.startOfDay(for: now)
      let gap = calendar.dateComponents([.day], from: latestStart, to: today).day ?? 0
      if gap <= 1 {
        var day = latestStart
        while activeDays.contains(day) {
          streak += 1
          guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
          day = previous
        }
      }
    }
    return ProfileActivity(
      lifetimeTokens: records.reduce(0) { $0 + $1.usage.totalTokens },
      peakTokens: records.map(\.usage.totalTokens).max() ?? 0,
      activeStreak: streak, taskCount: tasks.count, turnCount: localRuns.count,
      longestTaskTitle: longest?.0, longestTaskDuration: longest?.1 ?? 0)
  }
}

enum ProfileStorage {
  static let avatarName = "profile-avatar.png"
  static let maximumAvatarBytes = 5 * 1_024 * 1_024

  static func load(root: URL) throws -> ProfilePreferences {
    let url = root.appendingPathComponent("profile.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return ProfilePreferences() }
    let profile = try JSONDecoder().decode(ProfilePreferences.self, from: Data(contentsOf: url)).validated()
    if profile.hasAvatar,
      !FileManager.default.fileExists(atPath: root.appendingPathComponent(avatarName).path)
    {
      throw AgentFailure(message: "个人头像文件缺失，请重新选择头像。")
    }
    return profile
  }

  static func save(_ profile: ProfilePreferences, root: URL) throws {
    let profile = try profile.validated()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("profile.json")
    try JSONEncoder().encode(profile).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  static func normalizedAvatar(_ data: Data) throws -> Data {
    guard data.count <= maximumAvatarBytes, let image = NSImage(data: data),
      let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
      bitmap.pixelsWide <= 8_192, bitmap.pixelsHigh <= 8_192,
      let png = bitmap.representation(using: .png, properties: [:]),
      png.count <= maximumAvatarBytes
    else { throw AgentFailure(message: "头像须为有效图片，最大 5 MiB、8192 × 8192 像素。") }
    return png
  }

  static func avatarURL(root: URL) -> URL { root.appendingPathComponent(avatarName) }
}

enum ProfileCardRenderer {
  static func render(profile: ProfilePreferences, activity: ProfileActivity) throws -> Data {
    let width = 900
    let height = 520
    guard let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { throw AgentFailure(message: "无法生成个人资料卡。") }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let size = NSSize(width: width, height: height)
    let bounds = NSRect(origin: .zero, size: size)
    NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.09, alpha: 1).setFill()
    bounds.fill()
    NSColor(calibratedRed: 0.17, green: 0.48, blue: 0.96, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 54, y: 348, width: 112, height: 112), xRadius: 56, yRadius: 56).fill()

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    draw(
      profile.initials, in: NSRect(x: 54, y: 380, width: 112, height: 50),
      font: .systemFont(ofSize: 36, weight: .semibold), color: .white, paragraph: paragraph)
    draw(
      profile.displayName.isEmpty ? "ShipiOS 用户" : profile.displayName,
      in: NSRect(x: 194, y: 405, width: 650, height: 52),
      font: .systemFont(ofSize: 36, weight: .bold), color: .white)
    if !profile.username.isEmpty {
      draw("@" + profile.username, in: NSRect(x: 196, y: 368, width: 620, height: 32), font: .systemFont(ofSize: 20), color: .lightGray)
    }
    draw("ShipiOS 本地活动", in: NSRect(x: 56, y: 300, width: 500, height: 34), font: .systemFont(ofSize: 20, weight: .medium), color: .lightGray)

    let values = [
      ("终身 token", activity.lifetimeTokens.formatted()),
      ("单次峰值", activity.peakTokens.formatted()),
      ("连续活跃", "\(activity.activeStreak) 天"),
      ("任务 / 回合", "\(activity.taskCount) / \(activity.turnCount)"),
    ]
    for (index, item) in values.enumerated() {
      let x = 56 + CGFloat(index % 2) * 418
      let y = 190 - CGFloat(index / 2) * 118
      NSColor(calibratedWhite: 1, alpha: 0.07).setFill()
      NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 386, height: 96), xRadius: 18, yRadius: 18).fill()
      draw(item.0, in: NSRect(x: x + 20, y: y + 57, width: 340, height: 24), font: .systemFont(ofSize: 15), color: .lightGray)
      draw(item.1, in: NSRect(x: x + 20, y: y + 20, width: 340, height: 38), font: .systemFont(ofSize: 26, weight: .semibold), color: .white)
    }
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw AgentFailure(message: "无法生成个人资料卡。")
    }
    return png
  }

  private static func draw(
    _ text: String, in rect: NSRect, font: NSFont, color: NSColor,
    paragraph: NSParagraphStyle? = nil
  ) {
    var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    if let paragraph { attributes[.paragraphStyle] = paragraph }
    text.draw(in: rect, withAttributes: attributes)
  }
}
