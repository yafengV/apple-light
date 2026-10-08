import AppKit
import SwiftUI

struct WorkspaceCommands: Commands {
  let store: WorkspaceStore
  @Environment(\.openWindow) private var openWindow
  @FocusedValue(\.gitWorkflowCommands) private var gitCommands
  @FocusedValue(\.mcpApprovalCommands) private var approvalCommands
  @FocusedValue(\.taskWindowCommands) private var taskWindowCommands
  @FocusedValue(\.imagePreviewActive) private var imagePreviewActive
  @FocusedValue(\.searchDialogActive) private var searchDialogActive
  @FocusedValue(\.taskRenameActive) private var taskRenameActive
  @FocusedValue(\.taskRenameUndo) private var taskRenameUndo
  var body: some Commands {
    CommandGroup(replacing: .undoRedo) {
      Button(taskRenameUndo?.undoTitle ?? "撤销") { performUndo(redo: false) }
        .keyboardShortcut("z", modifiers: .command).disabled(taskRenameUndo?.canUndo == false)
      Button(taskRenameUndo?.redoTitle ?? "重做") { performUndo(redo: true) }
        .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(taskRenameUndo?.canRedo == false)
    }
    CommandGroup(replacing: .appSettings) { command("settings") }
    CommandGroup(replacing: .newItem) {
      command("new")
      command("new-standalone")
      command("open")
      command("project-picker")
    }
    CommandMenu("任务") {
      command("send")
      command("steer-prompt")
      command("queue-prompt")
      command("clear-prompt")
      command("add-photos")
      command("capture-appshot")
      command("add-files")
      command("plan")
      command("reasoning-increase")
      command("reasoning-decrease")
      command("reasoning-cycle")
      command("dictation")
      command("stop")
      Button("批准当前请求") { performApproval { approvalCommands?.approve() } }.disabled(searchDialogActive == true || taskRenameActive == true || approvalCommands == nil || imagePreviewActive == true)
      Button("拒绝当前请求") { performApproval { approvalCommands?.decline() } }.disabled(searchDialogActive == true || taskRenameActive == true || approvalCommands == nil || imagePreviewActive == true)
      Divider()
      command("rename")
      command("pin")
      command("archive")
      command("unread")
      command("clear-unread")
      command("copy-task-link")
      command("copy-session-id")
      command("copy-conversation-path")
      command("open-side-chat")
      Divider()
      command("find")
      command("find-next")
      command("find-previous")
      command("search")
      command("previous-task")
      command("next-task")
      command("next-attention")
      ForEach(1...9, id: \.self) { command("focus-chat-\($0)") }
      ForEach(1...6, id: \.self) { command("recent-chat-\($0)") }
      command("back")
      command("forward")
    }
    CommandMenu("标签页") {
      Button(taskWindowCommands?.closeTitle ?? "关闭当前标签") { perform("tab-close") }
        .keyboardShortcut("w", modifiers: .command)
        .disabled(!commandEnabled("tab-close"))
      command("tab-close-others")
      Divider()
      command("previous-task")
      command("next-task")
      ForEach(1...9, id: \.self) { command("focus-tab-\($0)") }
    }
    CommandMenu("工作区") {
      command("palette")
      command("shortcuts")
      Divider()
      command("sidebar")
      command("activity")
      command("files")
      command("tree")
      command("review")
      command("review-open")
      command("browser-address")
      command("branch")
      if gitCommands?.visible("git.createBranch") == true { command("git.createBranch") }
      if gitCommands?.visible("git.openPullRequest") == true { command("git.openPullRequest") }
      if gitCommands?.visible("git.mergePullRequest") == true { command("git.mergePullRequest") }
      command("git.commit")
      if gitCommands?.visible("git.createPullRequest") == true {
        command("git.createPullRequest")
        command("git.createDraftPullRequest")
      }
      command("copy-location")
      command("terminal")
      command("bottom-panel")
      command("browser")
      command("browser-new")
      command("workspace-view")
      command("workspace-tabs")
      command("workspace-swap-panes")
      command("projects")
      command("plugins")
      command("automations")
      Divider()
      command("environment-action-1")
      ForEach(2...9, id: \.self) { slot in
        if commandEnabled("environment-action-\(slot)") { command("environment-action-\(slot)") }
      }
      command("doctor")
      command("build")
      command("model")
      command("toggle-worktree-mode")
    }
    CommandMenu("宠物") {
      command("pet")
      Button("宠物设置…") {
        guard searchDialogActive != true, taskRenameActive != true, imagePreviewActive != true else { return }
        store.openSettings(.pets)
        openWindow(id: "main")
      }.disabled(searchDialogActive == true || taskRenameActive == true || imagePreviewActive == true || !store.commandEnabled("settings"))
    }
    CommandMenu("弹出窗口") {
      Button("显示或隐藏弹出窗口") { store.popoutWindowToggleHandler?() }
    }
    CommandMenu("浏览器") {
      ForEach(BrowserKeyboardBridge.contextualCommands.filter { $0 != "browser-address" }, id: \.self) { id in command(id) }
      command("browser-reopen")
    }
  }
  private func performUndo(redo: Bool) {
    if WindowModalInteraction.blocksCommands(in: NSApp.keyWindow) {
      guard WindowModalInteraction.allowsTextEditing(in: NSApp.keyWindow) else { return }
      NSApp.sendAction(NSSelectorFromString(redo ? "redo:" : "undo:"), to: nil, from: nil)
      return
    }
    if let taskRenameUndo { taskRenameUndo.perform(redo) }
    else { NSApp.sendAction(NSSelectorFromString(redo ? "redo:" : "undo:"), to: nil, from: nil) }
  }
  private func command(_ id: String) -> some View {
    let item = DesktopCommand.all.first { $0.id == id }!
    let title = id == "copy-location"
      ? taskWindowCommands?.copyLocationTitle ?? store.copyLocationTarget?.menuTitle ?? item.title
      : item.title
    return Button(title) {
      guard searchDialogActive != true, taskRenameActive != true, imagePreviewActive != true else { return }
      perform(id)
    }
      .keyboardShortcut(BrowserKeyboardBridge.contextualCommands.contains(id) ? nil : store.shortcuts.binding(id)?.keyboardShortcut)
      .disabled(!commandEnabled(id))
  }
  private func commandEnabled(_ id: String) -> Bool {
    guard !WindowModalInteraction.blocksCommands(in: NSApp.keyWindow),
      searchDialogActive != true, taskRenameActive != true, imagePreviewActive != true else { return false }
    if let local = ComposerCommandContext.focused(in: NSApp.keyWindow), ComposerCommandContext.owned.contains(id) {
      return local.enabled.contains(id)
    }
    if GitWorkflowCommandContext.owns(id) { return gitCommands?.enabled(id) == true }
    if let taskWindowCommands, TaskWindowCommandContext.owns(id) {
      return taskWindowCommands.enabled.contains(id)
    }
    if (id == "back" || id == "forward"), store.workspace.browser.hasEditableFocus { return false }
    return store.commandEnabled(id)
  }
  private func perform(_ id: String) {
    guard commandEnabled(id) else { return }
    if let local = ComposerCommandContext.focused(in: NSApp.keyWindow), ComposerCommandContext.owned.contains(id) {
      _ = local.execute(id)
    } else if GitWorkflowCommandContext.owns(id) {
      gitCommands?.execute(id)
    } else if let taskWindowCommands, TaskWindowCommandContext.owns(id) {
      taskWindowCommands.execute(id)
      if id == "new" { openWindow(id: "main") }
    } else {
      store.executeCommand(id)
      if id == "project-picker", taskWindowCommands != nil { store.searchDialogReturnFocus = nil }
      if id == "settings" || id == "shortcuts" || id == "new-standalone" || id == "project-picker"
        || id == "activity" { openWindow(id: "main") }
    }
  }
  private func performApproval(_ action: () -> Void) {
    // Focused scene values may outlive the presentation of a sheet.
    guard searchDialogActive != true, taskRenameActive != true, imagePreviewActive != true, !store.hasSettingsConfirmation, let window = NSApp.keyWindow, window.attachedSheet == nil,
      window.sheetParent == nil, NSApp.modalWindow == nil,
      !WindowModalInteraction.blocksCommands(in: window) else { return }
    action()
  }
}
