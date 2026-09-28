import AppKit
import SwiftUI

struct SkillIconView: View {
  let skill: PluginSkillReference
  var large = false
  var size: CGFloat = 38
  var fallbackColor: Color = .accentColor
  var revision = UUID()
  @State private var icon: NSImage?

  private var url: URL? {
    large ? skill.interface.iconLargeURL ?? skill.interface.iconSmallURL
      : skill.interface.iconSmallURL ?? skill.interface.iconLargeURL
  }

  private var tint: Color {
    guard let hex = skill.interface.brandColor, let value = UInt32(hex.dropFirst(), radix: 16) else {
      return fallbackColor
    }
    return Color(red: Double((value >> 16) & 255) / 255,
      green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
  }

  var body: some View {
    Group {
      if let icon {
        Image(nsImage: icon).resizable().scaledToFit().padding(5)
      } else {
        Image(systemName: "wand.and.stars").font(.title3).foregroundStyle(tint)
      }
    }
    .frame(width: size, height: size)
    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
    .accessibilityHidden(true)
    .task(id: "\(url?.absoluteString ?? "")|\(revision)") {
      icon = nil
      guard let url else { return }
      let folder = skill.sourceFileURL.deletingLastPathComponent()
      let data = await Task.detached(priority: .utility) {
        try? PluginStorage.skillIconData(at: url, in: folder)
      }.value
      guard !Task.isCancelled, let data else { return }
      icon = NSImage(data: data)
    }
  }
}
