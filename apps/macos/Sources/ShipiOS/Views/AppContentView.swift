import SwiftUI

/// All product pages live inside the main window. Keep the workspace mounted so
/// opening settings does not discard scroll position, panel views, or the composer.
struct AppContentView: View {
  @Bindable var store: WorkspaceStore

  var body: some View {
    WorkspaceView(store: store)
      .environment(\.mcpApprovalSurfaceVisible, store.mainMCPApprovalVisible)
      .background(ModifiedEscapeBridge(store: store).frame(width: 0, height: 0))
      .background(WorkspaceKeyboardBridge(store: store).frame(width: 0, height: 0))
      .background(MCPApprovalKeyboardBridge(store: store, taskID: store.selectedTask?.id,
        visible: store.mainMCPApprovalVisible).frame(width: 0, height: 0))
      .focusedSceneValue(\.mcpApprovalCommands,
        store.mcpApprovalCommands(taskID: store.selectedTask?.id, visible: store.mainMCPApprovalVisible))
      .opacity(store.destination == .settings ? 0 : 1)
      .allowsHitTesting(store.destination != .settings)
      .disabled(store.destination == .settings)
      .accessibilityHidden(store.destination == .settings)
      .onExitCommand {
        if store.destination == .pluginDetail {
          store.closePluginDetail()
        } else if store.destination == .settings {
          store.closeSettingsFromKeyboard()
        } else if store.destination == .projects || store.destination == .plugins
          || store.destination == .automations
        {
          store.returnToWorkspace()
        }
      }
      .overlay {
        if store.retainsSettingsPage {
          RuntimeSettingsView(store: store)
            .transition(.identity)
            .opacity(store.destination == .settings ? 1 : 0)
            .allowsHitTesting(store.destination == .settings)
            .disabled(store.destination != .settings)
            .accessibilityHidden(store.destination != .settings)
        }
      }
      .disabled(store.hasSettingsConfirmation)
      .allowsHitTesting(!store.hasSettingsConfirmation)
      .accessibilityHidden(store.hasSettingsConfirmation)
      .overlay {
        if let request = store.archiveDeletion {
          ArchiveDeletionDialog(store: store, request: request).id(request.id)
        } else if store.shortcutResetRequested {
          SettingsConfirmationDialog(title: "恢复所有默认快捷键？",
            message: "这将移除全部自定义快捷键并恢复默认设置。",
            confirmLabel: "全部恢复", busyLabel: "正在恢复…", busy: store.resettingShortcuts,
            error: store.shortcutResetError, width: 420, identifier: "shortcut-reset-dialog",
            cancel: store.dismissShortcutReset,
            confirm: { Task { await store.confirmShortcutReset() } })
        }
      }
      .overlay(alignment: .top) {
        if !store.notices.items.isEmpty { WorkspaceNoticesView(store: store) }
      }
      // Global sheets belong to the active main window, not its disabled workspace.
      .sheet(item: $store.presentedOverlay, onDismiss: {
        store.restoreOverlayFocus()
      }) { overlay in
        switch overlay {
        case .commands: CommandPaletteView(store: store)
        case .taskSearch: TaskSearchView(store: store)
        case .fileSearch: FileSearchView(store: store)
        case .worktreeCreation:
          if let path = store.worktreeSource {
            WorktreeCreationView(store: store, root: URL(fileURLWithPath: path))
          }
        case .filePreview:
          if let file = store.previewFile { FileAttachmentPreview(file: file, root: store.dataRoot) }
        case .imagePreview:
          if let image = store.previewImage { ImageAttachmentPreview(image: image, root: store.dataRoot) }
        }
      }
      .disabled(store.restoringLibrary)
      .overlay {
        if store.restoringLibrary {
          ProgressView("正在恢复工作区…").padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
      }
  }
}
