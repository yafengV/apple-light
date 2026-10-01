struct GlobalDictationToggleState {
  enum Action: Equatable {
    case start(String)
    case stop(String)
    case cancelPending
  }

  private(set) var token: String?
  private(set) var starting = false

  mutating func press(activeTarget: String?, newToken: String) -> Action {
    if let token, activeTarget == token {
      self.token = nil
      starting = false
      return .stop(token)
    }
    if token != nil && starting {
      token = nil
      starting = false
      return .cancelPending
    }
    token = newToken
    starting = true
    return .start(newToken)
  }

  mutating func didResolveStart(token: String, active: Bool) {
    guard self.token == token else { return }
    starting = false
    if !active { self.token = nil }
  }

  mutating func cancel(token: String) {
    guard self.token == token else { return }
    self.token = nil
    starting = false
  }
}
