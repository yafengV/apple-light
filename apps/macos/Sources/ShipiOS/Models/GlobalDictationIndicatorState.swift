enum GlobalDictationIndicatorState: Equatable {
  case hidden
  case idle
  case initializing
  case listening
  case transcribing
  case error

  static func resolve(hasHotkey: Bool, target: String?, phase: SpeechDictation.Phase,
    hasError: Bool) -> Self {
    if let target, target.hasPrefix("global-dictation:") {
      switch phase {
      case .requestingAccess: return .initializing
      case .listening: return .listening
      case .finishing: return .transcribing
      case .idle: break
      }
    }
    if hasError { return .error }
    return hasHotkey ? .idle : .hidden
  }
}
