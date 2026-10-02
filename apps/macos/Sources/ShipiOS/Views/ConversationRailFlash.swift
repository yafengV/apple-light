import Observation
import SwiftUI

private struct ConversationRailFlashIDKey: EnvironmentKey {
  static let defaultValue: String? = nil
}

extension EnvironmentValues {
  var conversationRailFlashID: String? {
    get { self[ConversationRailFlashIDKey.self] }
    set { self[ConversationRailFlashIDKey.self] = newValue }
  }
}

@MainActor @Observable final class ConversationRailFlash {
  private(set) var id: String?
  @ObservationIgnored private var task: Task<Void, Never>?

  func flash(_ id: String, reduceMotion: Bool) {
    task?.cancel()
    guard !reduceMotion else { self.id = nil; return }
    self.id = id
    task = Task {
      try? await Task.sleep(for: .milliseconds(120))
      guard !Task.isCancelled, self.id == id else { return }
      withAnimation(.easeOut(duration: 0.85)) { self.id = nil }
    }
  }

  func clear() {
    task?.cancel()
    task = nil
    id = nil
  }
}

private struct ConversationRailFlashModifier: ViewModifier {
  @Environment(\.conversationRailFlashID) private var currentID
  let id: String
  let cornerRadius: CGFloat

  func body(content: Content) -> some View {
    content.overlay {
      RoundedRectangle(cornerRadius: cornerRadius)
        .fill(.primary.opacity(currentID == id ? 0.1 : 0))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }
}

extension View {
  func conversationRailFlash(_ id: String, cornerRadius: CGFloat = 16) -> some View {
    modifier(ConversationRailFlashModifier(id: id, cornerRadius: cornerRadius))
  }
}
