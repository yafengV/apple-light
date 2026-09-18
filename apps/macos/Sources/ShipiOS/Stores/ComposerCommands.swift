import Foundation

extension WorkspaceStore {
  var enabledComposerCommands: Set<ComposerCommand> {
    guard destination == .workspace else { return [] }
    return Set(ComposerCommand.allCases.filter {
      if let action = $0.localAction { return action == .chat || project != nil }
      return commandEnabled($0.actionID)
    })
  }

  func selectComposerCommand(_ command: ComposerCommand) {
    guard enabledComposerCommands.contains(command) else { return }
    if command == .review {
      draft = ""
      presentCodeReviewMode()
      return
    }
    if command == .plan {
      if chatMode == .goal { leaveGoalMode() }
      action = .chat
      chatMode = .plan
      draft = ""
      focusComposer = UUID()
      return
    }
    if command == .goal {
      action = .chat
      draft = ""
      showingGoalEditor = true
      return
    }
    if let action = command.localAction {
      if chatMode == .goal { leaveGoalMode() }
      self.action = action
      chatMode = .standard
      draft = command.token + " "
    } else {
      draft = command.token
      _ = handleComposerCommand()
    }
    if destination == .workspace, !showingModelPicker, presentedOverlay == nil {
      focusComposer = UUID()
    }
  }
}
