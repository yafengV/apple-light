import SwiftUI

/// An original, muted walkthrough for the Appshot settings page. Keep its
/// animation local to the visible page so hidden settings do not keep drawing.
struct AppshotDemoView: View {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.appAppearance) private var appearance
  @State private var startedAt = Date()

  var body: some View {
    TimelineView(.animation(minimumInterval: 0.25,
      paused: !isEnabled || appearance.shouldReduceMotion)) { timeline in
      let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
      let stage = appearance.shouldReduceMotion ? 2 : Int(elapsed / 3.4) % 4
      demo(stage: stage)
        .animation(.easeInOut(duration: 0.4), value: stage)
    }
    .aspectRatio(901.0 / 1095.0, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 16))
    .overlay(RoundedRectangle(cornerRadius: 16)
      .strokeBorder(.primary.opacity(0.12), lineWidth: 1))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("应用快照演示")
    .accessibilityHint("同时按下快捷键，将当前应用窗口的截图和文字附加到聊天。")
    .onChange(of: isEnabled) { _, enabled in
      if enabled { startedAt = Date() }
    }
  }

  private func demo(stage: Int) -> some View {
    GeometryReader { geometry in
      ZStack {
        LinearGradient(colors: [Color.accentColor.opacity(0.2), .black.opacity(0.07)],
          startPoint: .topLeading, endPoint: .bottomTrailing)
        VStack(spacing: 0) {
          HStack {
            Text("ShipiOS 演示").font(.system(size: 9, weight: .medium))
            Spacer()
            Image(systemName: "wifi")
            Image(systemName: "battery.100percent")
          }
          .foregroundStyle(.secondary)
          .padding(.horizontal, 12).padding(.top, 10)
          Spacer(minLength: 12)
          sourceWindow
            .frame(height: geometry.size.height * 0.43)
            .padding(.horizontal, 16)
          Spacer(minLength: 12)
          keyboard(highlighted: stage == 1)
            .frame(height: geometry.size.height * 0.26)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        if stage >= 2 {
          chatWindow(showAnswer: stage == 3)
            .frame(width: geometry.size.width * 0.75,
              height: geometry.size.height * 0.47)
            .offset(y: -geometry.size.height * 0.07)
            .transition(.opacity.combined(with: .scale(scale: 0.94)))
        }
      }
    }
  }

  private var sourceWindow: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 4) {
        Circle().fill(.red.opacity(0.8)).frame(width: 6, height: 6)
        Circle().fill(.yellow.opacity(0.8)).frame(width: 6, height: 6)
        Circle().fill(.green.opacity(0.8)).frame(width: 6, height: 6)
        Spacer()
        Text("Xcode · SampleApp.swift")
          .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
        Spacer()
      }
      .padding(8)
      Divider()
      VStack(alignment: .leading, spacing: 7) {
        Text("SampleApp.swift")
          .font(.system(size: 11, weight: .semibold))
        Text("struct SampleApp: App {")
        Text("  var body: some Scene {")
        Text("    WindowGroup {")
        Text("      ContentView()")
        Text("    }")
        Text("  }")
        Text("}")
      }
      .font(.system(size: 10, design: .monospaced))
      .foregroundStyle(.primary)
      .padding(12)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
    .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
  }

  private func keyboard(highlighted: Bool) -> some View {
    VStack(spacing: 5) {
      ForEach(0..<3) { row in
        HStack(spacing: 4) {
          ForEach(0..<9) { column in
            let commandKey = row == 2 && (column == 0 || column == 8)
            RoundedRectangle(cornerRadius: 3)
              .fill(commandKey && highlighted ? appearance.accentColor : .black.opacity(0.6))
              .overlay {
                if commandKey {
                  Text("⌘").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                }
              }
          }
        }
      }
    }
    .padding(10)
    .background(.gray.opacity(0.45), in: RoundedRectangle(cornerRadius: 13))
  }

  private func chatWindow(showAnswer: Bool) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Image(systemName: "shippingbox.fill")
          .foregroundStyle(appearance.accentColor)
        Text("ShipiOS").font(.system(size: 11, weight: .semibold))
        Spacer()
        Image(systemName: "ellipsis")
      }
      Divider()
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "macwindow")
          .font(.system(size: 15)).foregroundStyle(appearance.accentColor)
        VStack(alignment: .leading, spacing: 4) {
          Text("SampleApp.swift")
            .font(.system(size: 10, weight: .medium))
          Text("窗口截图与文字已附加")
            .font(.system(size: 9)).foregroundStyle(.secondary)
        }
      }
      .padding(8)
      .background(appearance.accentColor.opacity(0.09),
        in: RoundedRectangle(cornerRadius: 8))
      Text("帮我检查这个窗口")
        .font(.system(size: 11))
      if showAnswer {
        Text("已查看窗口内容，可以从这里继续。")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      RoundedRectangle(cornerRadius: 7)
        .strokeBorder(.primary.opacity(0.2))
        .frame(height: 28)
        .overlay(alignment: .leading) {
          Text("向 ShipiOS 发送消息…")
            .font(.system(size: 9)).foregroundStyle(.tertiary)
            .padding(.leading, 9)
        }
    }
    .padding(12)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
  }
}
