import SwiftUI

struct MCPResultAudioView: View {
  let base64: String
  let mime: String
  @Environment(\.mcpApprovalSurfaceVisible) private var visible
  @State private var playback = MCPAudioPlayback()
  @State private var decodeError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let error = decodeError ?? playback.error {
        Label(error, systemImage: "waveform.badge.exclamationmark").foregroundStyle(.secondary)
      } else {
        HStack {
          Button { playback.toggle() } label: {
            Image(systemName: playback.playing ? "pause.fill" : "play.fill")
          }.accessibilityLabel(playback.playing ? "暂停工具音频" : "播放工具音频")
          Slider(value: Binding(get: { playback.position }, set: { playback.seek($0) }),
            in: 0...max(0.01, playback.duration)).accessibilityLabel("音频播放位置")
          Text("\(time(playback.position)) / \(time(playback.duration))")
            .appFont(.caption).monospacedDigit()
        }.disabled(playback.duration == 0)
      }
    }.padding(10).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
      .task(id: base64 + mime) {
        playback.stop(); decodeError = nil
        do {
          let source = base64, type = mime
          let data = try await Task.detached(priority: .userInitiated) {
            try MCPResultMedia.decode(source, mime: type, kind: "audio")
          }.value
          guard !Task.isCancelled else { return }
          playback.load(data)
        } catch { if !Task.isCancelled { decodeError = error.localizedDescription } }
      }
      .onDisappear { playback.stop() }
      .onChange(of: visible) { _, visible in if !visible { playback.pause() } }
  }
  private func time(_ seconds: Double) -> String {
    let value = Int(max(0, seconds))
    return String(format: "%d:%02d", value / 60, value % 60)
  }
}
