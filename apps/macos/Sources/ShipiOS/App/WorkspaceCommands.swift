import AppKit
import SwiftUI

struct WorkspaceCommands: Commands {
  let store: WorkspaceStore
  @Environment(\.openWindow) private var openWindow
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
      command("new-alternate")
      command("open")
    }
    CommandMenu("任务") {
      command("send")
      command("stop")
      Button("批准当前请求") { performApproval { approvalCommands?.approve() } }.disabled(searchDialogActive == true || taskRenameActive == true || approvalCommands == nil || imagePreviewActive == true)
      Button("拒绝当前请求") { performApproval { approvalCommands?.decline() } }.disabled(searchDialogActive == true || taskRenameActive == true || approvalCommands == nil || imagePreviewActive == true)
      Divider()
      command("rename")
      command("pin")
      command("archive")
      command("unread")
      command("clear-unread")
      Divider()
      command("find")
      command("find-next")
      command("find-previous")
      command("search")
      command("previous-task")
      command("next-task")
      command("next-attention")
      ForEach(1...9, id: \.self) { command("focus-chat-\($0)") }
      command("back")
      command("forward")
    }
    CommandMenu("标签页") {
      Button(taskWindowCommands == nil ? "关闭当前标签" : "关闭任务窗口") { perform("tab-close") }
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
      command("palette-alternate")
      command("shortcuts")
      Divider()
      command("sidebar")
      command("files")
      command("tree")
      command("review")
      command("review-open")
      command("browser-address")
      command("branch")
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
      command("doctor")
      command("build")
      command("model")
    }
    CommandMenu("宠物") {
      command("pet")
      Button("宠物设置…") {
        guard searchDialogActive != true, taskRenameActive != true, imagePreviewActive != true else { return }
        store.openSettings(.pets)
        openWindow(id: "main")
      }.disabled(searchDialogActive == true || taskRenameActive == true || imagePreviewActive == true || !store.commandEnabled("settings"))
    }
    CommandMenu("浏览器") {
      ForEach(BrowserKeyboardBridge.contextualCommands.filter { $0 != "browser-address" }, id: \.self) { id in command(id) }
      command("browser-reopen")
    }
  }
  private func performUndo(redo: Bool) {
    if let taskRenameUndo { taskRenameUndo.perform(redo) }
    else { NSApp.sendAction(NSSelectorFromString(redo ? "redo:" : "undo:"), to: nil, from: nil) }
  }
  private func command(_ id: String) -> some View {
    let item = DesktopCommand.all.first { $0.id == id }!
    return Button(item.title) {
      guard searchDialogActive != true, taskRenameActive != true, imagePreviewActive != true else { return }
      perform(id)
    }
      .keyboardShortcut(BrowserKeyboardBridge.contextualCommands.contains(id) ? nil : store.shortcuts.binding(id)?.keyboardShortcut)
      .disabled(!commandEnabled(id))
  }
  private func commandEnabled(_ id: String) -> Bool {
    guard searchDialogActive != true, taskRenameActive != true, imagePreviewActive != true else { return false }
    if let taskWindowCommands, TaskWindowCommandContext.owns(id) {
      return taskWindowCommands.enabled.contains(id)
    }
    return store.commandEnabled(id)
  }
  private func perform(_ id: String) {
    guard commandEnabled(id) else { return }
    if let taskWindowCommands, TaskWindowCommandContext.owns(id) {
      taskWindowCommands.execute(id)
    } else {
      store.executeCommand(id)
      if id == "settings" || id == "shortcuts" { openWindow(id: "main") }
    }
  }
  private func performApproval(_ action: () -> Void) {
    // Focused scene values may outlive the presentation of a sheet.
    guard searchDialogActive != true, taskRenameActive != true, imagePreviewActive != true, !store.hasSettingsConfirmation, let window = NSApp.keyWindow, window.attachedSheet == nil,
      window.sheetParent == nil, NSApp.modalWindow == nil else { return }
    action()
  }
}
