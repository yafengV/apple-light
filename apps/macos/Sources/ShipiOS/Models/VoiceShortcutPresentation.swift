import Foundation
import Observation

/// Temporary page state. Bindings themselves remain in VoicePreferences.
@MainActor @Observable final class VoiceShortcutPresentation {
  enum Mode: String, Hashable, CaseIterable {
    case hold, toggle, voiceChat
    var commandID: String {
      switch self {
      case .hold: "globalDictationHold"
      case .toggle: "globalDictationSingleTap"
      case .voiceChat: "realtimeVoice"
      }
    }
    init?(commandID: String) {
      switch commandID {
      case "globalDictationHold": self = .hold
      case "globalDictationSingleTap": self = .toggle
      case "realtimeVoice": self = .voiceChat
      default: return nil
      }
    }
    var title: String {
      switch self {
      case .hold: "按住听写"
      case .toggle: "单击听写"
      case .voiceChat: "语音聊天"
      }
    }
  }
  private(set) var recording: Mode?
  private(set) var captureID: UUID?
  var modifierCapture = VoiceModifierCaptureState()
  var warnings: [Mode: String] = [:]

  func begin(_ mode: Mode) {
    warnings[mode] = nil
    modifierCapture.reset()
    captureID = UUID()
    recording = mode
  }
  func owns(_ mode: Mode, id: UUID?) -> Bool {
    id != nil && captureID == id && recording == mode
  }
  @discardableResult func end(_ mode: Mode, id: UUID?) -> Bool {
    guard owns(mode, id: id) else { return false }
    recording = nil; captureID = nil; modifierCapture.reset()
    return true
  }
  func reset() {
    recording = nil; captureID = nil; modifierCapture.reset(); warnings.removeAll()
  }
}
