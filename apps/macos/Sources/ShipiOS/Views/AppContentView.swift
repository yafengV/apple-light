import SwiftUI

/// All product pages live inside the main window. Keep the workspace mounted so
/// opening settings does not discard scroll position, panel views, or the composer.
struct AppContentView: View {
  @Bindable var store: WorkspaceStore
  @State private var imagePreviewReturnFocus: (() -> Void)?

  var body: some View {
    WorkspaceView(store: store)
      .environment(\.presentImageGallery) { image, images, returnFocus in
        guard store.presentedOverlay == nil, !store.hasSettingsConfirmation else { return }
        imagePreviewReturnFocus = returnFocus
        store.preview(image, images: images)
      }
      .environment(\.mcpApprovalSurfaceVisible, store.mainMCPApprovalVisible)
      .background(ModifiedEscapeBridge(store: store).frame(width: 0, height: 0))
      .background(MCPApprovalKeyboardBridge(store: store, taskID: store.selectedTask?.id,
        visible: store.mainMCPApprovalVisible).frame(width: 0, height: 0))
      .focusedSceneValue(\.mcpApprovalCommands,
        store.mcpApprovalCommands(taskID: store.selectedTask?.id, visible: store.mainMCPApprovalVisible))
      .opacity(store.destination == .settings ? 0 : 1)
      .allowsHitTesting(store.destination != .settings)
      .disabled(store.destination == .settings)
      .accessibilityElement(children: .contain)
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
            .accessibilityElement(children: .contain)
            .accessibilityHidden(store.destination != .settings)
        }
      }
      .disabled(store.hasSettingsConfirmation || store.presentedOverlay == .imagePreview || store.presentedOverlay == .fileSearch)
      .allowsHitTesting(!store.hasSettingsConfirmation && store.presentedOverlay != .imagePreview && store.presentedOverlay != .fileSearch)
      .accessibilityHidden(store.hasSettingsConfirmation || store.presentedOverlay == .imagePreview || store.presentedOverlay == .fileSearch)
      .overlay {
        if let request = store.archiveDeletion {
          ArchiveDeletionDialog(store: store, request: request).id(request.id)
        } else if let request = store.memoryDeletion {
          SettingsConfirmationDialog(title: request.title, message: request.message,
            confirmLabel: "删除", busyLabel: "正在删除…", busy: store.deletingMemories,
            error: store.memoryDeletionError, width: 420, identifier: "memory-deletion-dialog",
            cancel: store.dismissMemoryDeletion,
            confirm: { Task { await store.confirmMemoryDeletion() } }).id(request.id)
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
      .overlay {
        if store.presentedOverlay == .imagePreview, let image = store.previewImage {
          ImageGalleryPreview(image: image, images: store.previewImages, root: store.dataRoot) {
            store.setOverlay(.imagePreview, presented: false)
          }.id(image.id)
        }
      }
      .overlay {
        if store.presentedOverlay == .fileSearch { FileSearchView(store: store) }
      }
      .focusedSceneValue(\.fileSearchActive, store.presentedOverlay == .fileSearch)
      .onChange(of: store.presentedOverlay) { previous, current in
        if previous == .fileSearch, current == nil { store.restoreOverlayFocus() }
        if previous == .imagePreview, current == nil {
          let returnFocus = imagePreviewReturnFocus
          imagePreviewReturnFocus = nil
          if let returnFocus {
            DispatchQueue.main.async {
              guard store.presentedOverlay == nil, store.destination == .workspace else { return }
              returnFocus()
            }
          } else { store.restoreOverlayFocus() }
        }
      }
      .focusedSceneValue(\.imagePreviewActive, store.presentedOverlay == .imagePreview)
      // Global sheets belong to the active main window, not its disabled workspace.
      .sheet(item: Binding(get: { [.imagePreview, .fileSearch].contains(store.presentedOverlay) ? nil : store.presentedOverlay },
        set: { if ![.imagePreview, .fileSearch].contains(store.presentedOverlay) { store.presentedOverlay = $0 } }), onDismiss: {
        store.restoreOverlayFocus()
      }) { overlay in
        switch overlay {
        case .commands: CommandPaletteView(store: store)
        case .taskSearch: TaskSearchView(store: store)
        case .fileSearch: EmptyView()
        case .worktreeCreation:
          if let path = store.worktreeSource {
            WorktreeCreationView(store: store, root: URL(fileURLWithPath: path))
          }
        case .filePreview:
          if let file = store.previewFile { FileAttachmentPreview(file: file, root: store.dataRoot) }
        case .imagePreview:
          EmptyView()
        }
      }
      .disabled(store.restoringLibrary)
      .overlay {
        if store.restoringLibrary {
          ProgressView("正在恢复工作区…").padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
      }
      // Keep the window keyboard route attached while the workspace is hidden
      // behind settings. SwiftUI may detach zero-opacity native backgrounds.
      .background(WorkspaceKeyboardBridge(store: store).frame(width: 0, height: 0))
  }
}
