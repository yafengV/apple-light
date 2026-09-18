import AppKit
import SwiftUI

struct MCPResultImageView: View {
  let base64: String
  let mime: String
  @State private var image: NSImage?
  @State private var error: String?
  let preview: (@escaping () -> Void) -> Void
  @FocusState private var thumbnailFocused: Bool
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    Group {
      if let image {
        Button(action: open) {
          Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 192)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).focusable().focused($thumbnailFocused).accessibilityLabel("预览工具返回的图片")
          .onKeyPress(keys: [.space, .return], phases: .down) { press in
            guard isEnabled, press.modifiers.isEmpty else { return .ignored }
            open()
            return .handled
          }
      } else if let error {
        Label(error, systemImage: "photo.badge.exclamationmark").foregroundStyle(.secondary)
      } else { ProgressView().controlSize(.small) }
    }.task(id: base64 + mime) {
      image = nil; error = nil
      do {
        let source = base64, type = mime
        let result = try await Task.detached(priority: .userInitiated) {
          try MCPResultMedia.thumbnail(base64: source, mime: type, size: 640)
        }.value
        guard !Task.isCancelled else { return }
        image = NSImage(cgImage: result, size: .zero)
      } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
  }
  private func open() {
    guard isEnabled else { return }
    thumbnailFocused = false
    preview { thumbnailFocused = true }
  }
}
