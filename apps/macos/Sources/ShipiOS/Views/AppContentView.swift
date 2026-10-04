import AppKit
import SwiftUI

/// All product pages live inside the main window. Keep the workspace mounted so
/// opening settings does not discard scroll position, panel views, or the composer.
struct AppContentView: View {
  @Bindable var store: WorkspaceStore
  @State private var imagePreviewReturnFocus: (() -> Void)?
  @State private var noticeHostTracker = NoticeHostBoundsTracker()
  @Environment(\.noticeHostBoundsTracker) private var suppliedNoticeHostTracker
  @Environment(\.openWindow) private var openWindow

  private var activeNoticeHostTracker: NoticeHostBoundsTracker {
    suppliedNoticeHostTracker ?? noticeHostTracker
  }

  var body: some View {
    WorkspaceView(store: store)
      .coordinateSpace(name: NoticeHostBounds.coordinateSpace)
      .environment(\.noticeHostBoundsTracker, activeNoticeHostTracker)
      .environment(\.presentImageGallery) { image, images, returnFocus in
        guard store.presentedOverlay == nil, !store.hasSettingsConfirmation else { return }
        imagePreviewReturnFocus = returnFocus
        store.preview(image, images: images)
      }
      .environment(\.mcpApprovalSurfaceVisible, store.mainMCPApprovalVisible)
      .onAppear {
        store.showMainWindowHandler = {
          openWindow(id: "main")
          DispatchQueue.main.async {
            if let main = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
              if main.isMiniaturized { main.deminiaturize(nil) }
              main.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
          }
        }
      }
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
        if store.appshotIntroRequest != nil {
          store.cancelAppshotIntro()
        } else if store.destination == .pluginDetail {
          store.closePluginDetail()
        } else if store.destination == .settings {
          store.closeSettingsFromKeyboard()
        } else if store.showingActivity {
          store.closeActivity()
        } else if store.destination == .projects || store.destination == .plugins
          || store.destination == .skills
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
      // Keep the hidden workspace's accessibility boundary separate from the
      // active settings page and the outer modal boundary.
      .accessibilityElement(children: .contain)
      .disabled(((store.hasSettingsConfirmation || store.appshotIntroRequest != nil)
        && store.appearanceThemeImport == nil)
        || store.presentedOverlay == .imagePreview || store.presentedOverlay?.isSearchDialog == true)
      .allowsHitTesting(!store.hasSettingsConfirmation && store.appshotIntroRequest == nil
        && store.presentedOverlay != .imagePreview && store.presentedOverlay?.isSearchDialog != true)
      .accessibilityHidden(store.hasSettingsConfirmation || store.appshotIntroRequest != nil
        || store.presentedOverlay == .imagePreview || store.presentedOverlay?.isSearchDialog == true)
      .overlay {
        if store.pendingSettingsNavigation != nil {
          SettingsConfirmationDialog(title: "丢弃更改？",
            message: "你有未保存的更改。现在离开将丢失这些更改。",
            confirmLabel: "丢弃更改", busyLabel: "丢弃更改", busy: false,
            error: nil, width: 420, identifier: "settings-unsaved-changes-dialog",
            cancelLabel: "继续编辑", cancel: store.cancelDiscardSettingsChanges,
            confirm: store.confirmDiscardSettingsChanges)
        } else if let session = store.appearanceThemeImport {
          AppearanceThemeImportView(store: store, session: session).id(session.id)
        } else if let request = store.archiveConfirmation() {
          ActivityArchiveDialog(store: store, request: request).id(request.id)
        } else if let request = store.archiveDeletion {
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
        let host = activeNoticeHostTracker.bounds.rect(for: store.destination)
        let root = activeNoticeHostTracker.bounds.root
        WorkspaceNoticesView(store: store)
          .frame(width: host?.width, alignment: .top)
          .offset(x: (host?.midX ?? root?.midX ?? 0) - (root?.midX ?? host?.midX ?? 0),
            y: (host?.minY ?? 0) - (root?.minY ?? 0))
          .allowsHitTesting(!store.notices.items.isEmpty)
      }
      .overlay {
        if store.presentedOverlay == .imagePreview, let image = store.previewImage {
          ImageGalleryPreview(image: image, images: store.previewImages, root: store.dataRoot) {
            store.setOverlay(.imagePreview, presented: false)
          }.id(image.id)
        }
      }
      .overlay {
        switch store.presentedOverlay {
        case .commands: CommandPaletteView(store: store)
        case .taskSearch: TaskSearchView(store: store)
        case .fileSearch: FileSearchView(store: store)
        case .projectPicker: ProjectPickerView(store: store)
        default: EmptyView()
        }
      }
      .overlay {
        if let request = store.appshotIntroRequest {
          AppshotIntroDialog(
            cancel: { store.cancelAppshotIntro() },
            enable: { store.acceptAppshotIntro() })
            .id(request.id)
        }
      }
      .focusedSceneValue(\.searchDialogActive, store.presentedOverlay?.isSearchDialog == true)
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
      .sheet(item: Binding(get: { store.presentedOverlay?.usesWindowOverlay == true ? nil : store.presentedOverlay },
        set: { if store.presentedOverlay?.usesWindowOverlay != true { store.presentedOverlay = $0 } }), onDismiss: {
        store.restoreOverlayFocus()
      }) { overlay in
        switch overlay {
        case .commands, .taskSearch, .fileSearch, .projectPicker: EmptyView()
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
      .overlay {
        if store.voiceChatPresented { RealtimeVoiceOverlay(store: store) }
      }
      .overlay {
        if let burst = store.confettiBurst {
          ConfettiOverlay(burst: burst) {
            if store.confettiBurst == burst { store.confettiBurst = nil }
          }
        }
      }
      // Keep the window keyboard route attached while the workspace is hidden
      // behind settings. SwiftUI may detach zero-opacity native backgrounds.
      .background(WorkspaceKeyboardBridge(store: store).frame(width: 0, height: 0))
  }
}
