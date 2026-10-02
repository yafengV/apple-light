import SwiftUI

/// A short, window-local celebration. Canvas draws deterministic particles so
/// animation frames never mutate workspace state or intercept input.
struct ConfettiOverlay: View {
  let burst: UUID
  let onFinished: () -> Void
  @State private var startedAt = Date()

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
      Canvas { context, size in
        let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
        guard elapsed < 3 else { return }
        for index in 0..<90 {
          let spread = Double((index * 67) % 89) / 89 - 0.5
          let horizontal = Double((index * 31) % 97) / 97 - 0.5
          let x = size.width * (0.5 + spread * 0.92)
            + horizontal * elapsed * 95
          let y = -25 + Double((index * 19) % 61)
            + elapsed * (70 + Double((index * 41) % 150))
            + elapsed * elapsed * 105
          guard y < size.height + 15 else { continue }
          let width = 5 + CGFloat(index % 4)
          let height = 8 + CGFloat((index * 3) % 5)
          let rect = CGRect(x: x, y: y, width: width, height: height)
          let color: Color = switch index % 6 {
          case 0: .pink
          case 1: .yellow
          case 2: .mint
          case 3: .blue
          case 4: .orange
          default: .purple
          }
          context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color.opacity(max(0, 1 - elapsed / 3))))
        }
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
    .task(id: burst) {
      startedAt = .now
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      onFinished()
    }
  }
}
