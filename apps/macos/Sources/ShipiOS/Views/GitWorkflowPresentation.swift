import SwiftUI

private struct GitWorkflowPresentation: ViewModifier {
  @Bindable var store: WorkspaceStore
  @Bindable var workspace: DeveloperWorkspace
  let taskID: String?
  let available: () -> Bool
  let currentTaskID: () -> String?
  let keyboardAllowed: () -> Bool
  let openPullRequestLink: (@MainActor (URL) async -> Bool)?
  let selectedPullRequest: (() -> GitHubPullRequest?)?
  let activePullRequestURLs: (() -> [String])?
  let openPullRequestDetails: (@MainActor (GitHubPullRequest, Bool) async -> Bool)?

  private var request: GitWorkflowCommandRequest {
    .init(repository: .init(root: workspace.gitAvailable ? workspace.gitRoot : nil,
      revision: workspace.reviewSnapshot, generation: workspace.generationForGitMutation,
      epoch: workspace.reviewRepositoryEpoch, taskID: taskID,
      suspended: workspace.gitRefreshing || workspace.gitBusy || workspace.gitActionRunning
        || workspace.generatingCommitMessage || workspace.pullRequestDraft.creating),
      primary: workspace.isPrimaryReviewRepository)
  }
  private var commands: GitWorkflowCommandContext {
    .init(store: store, workspace: workspace, taskID: taskID, request: request,
      available: available, currentTaskID: currentTaskID, openPullRequestLink: openPullRequestLink,
      selectedPullRequest: selectedPullRequest, activePullRequestURLs: activePullRequestURLs,
      openPullRequestDetails: openPullRequestDetails)
  }
  func body(content: Content) -> some View {
    content
      .focusedSceneValue(\.gitWorkflowCommands, commands)
      .background(GitWorkflowKeyboardBridge(commands: commands,
        shortcuts: store.shortcuts, allowed: keyboardAllowed).frame(width: 0, height: 0))
      .task(id: request) {
        let draft = workspace.pullRequestDraft
        await workspace.gitCommands.load(request) { root, primary in
          try await GitWorkflowCommandSnapshot.capture(at: root, primary: primary) {
            try await draft.inspectEntry(at: $0)
          }
        }
      }
      .task(id: commands.mergeRequest) {
        await workspace.pullRequestMergeCommand.load(commands.mergeRequest)
      }
      .sheet(isPresented: $workspace.showingCommitPush, onDismiss: workspace.clearGitPresentation) {
        GitCommitPushView(store: store, workspace: workspace,
          taskTitle: store.gitCommitTaskTitle(taskID: workspace.gitPresentationTaskID))
      }
      .sheet(isPresented: $workspace.showingPullRequest, onDismiss: workspace.clearGitPresentation) {
        GitHubPRView(store: store, workspace: workspace, draft: workspace.pullRequestDraft,
          taskID: workspace.gitPresentationTaskID, forceDraft: workspace.gitPresentationForceDraft)
      }
      .sheet(isPresented: $workspace.showingManagedBranchSetup, onDismiss: {
        store.finishManagedBranchPresentation(in: workspace)
      }) {
        if let request = workspace.managedBranchRequest {
          GitManagedBranchSetupView(store: store, workspace: workspace, request: request)
        }
      }
      .onChange(of: taskID) { _, _ in
        workspace.showingCommitPush = false; workspace.showingPullRequest = false
        workspace.showingManagedBranchSetup = false; workspace.managedBranchRequest = nil
        workspace.managedBranchSetup.cancel()
        workspace.pullRequestLinkOpening.cancel(); workspace.pullRequestMergeCommand.cancel()
        workspace.clearGitPresentation()
      }
      .onDisappear { workspace.gitCommands.cancel(); workspace.pullRequestLinkOpening.cancel(); workspace.pullRequestMergeCommand.cancel() }
  }
}

extension View {
  func gitWorkflowPresentation(store: WorkspaceStore, workspace: DeveloperWorkspace,
    taskID: String?, currentTaskID: @escaping () -> String?,
    keyboardAllowed: @escaping () -> Bool,
    openPullRequestLink: (@MainActor (URL) async -> Bool)? = nil,
    selectedPullRequest: (() -> GitHubPullRequest?)? = nil,
    activePullRequestURLs: (() -> [String])? = nil,
    openPullRequestDetails: (@MainActor (GitHubPullRequest, Bool) async -> Bool)? = nil,
    available: @escaping () -> Bool) -> some View {
    modifier(GitWorkflowPresentation(store: store, workspace: workspace,
      taskID: taskID, available: available, currentTaskID: currentTaskID, keyboardAllowed: keyboardAllowed,
      openPullRequestLink: openPullRequestLink, selectedPullRequest: selectedPullRequest, activePullRequestURLs: activePullRequestURLs, openPullRequestDetails: openPullRequestDetails))
  }
}

/// Handles every configured binding, including alternate bindings and detached windows.
private struct GitWorkflowKeyboardBridge: NSViewRepresentable {
  let commands: GitWorkflowCommandContext
  let shortcuts: ShortcutPreferences
  let allowed: () -> Bool
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView {
    let view = NSView(); context.coordinator.install(view); return view
  }
  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.handle = { binding in
      guard allowed(), let id = commands.command(for: binding, shortcuts: shortcuts) else { return false }
      return commands.execute(id)
    }
  }
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }
  final class Coordinator {
    var handle: ((ShortcutBinding) -> Bool)?
    private var monitor: Any?
    func install(_ view: NSView) {
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
        MainActor.assumeIsolated {
          guard let window = view?.window, window.isKeyWindow, event.window === window,
            window.attachedSheet == nil, window.sheetParent == nil, NSApp.modalWindow == nil,
            (window.firstResponder as? NSTextView)?.hasMarkedText() != true,
            let binding = ShortcutBinding(event: event) else { return event }
          return self?.handle?(binding) == true ? nil : event
        }
      }
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; handle = nil }
    deinit { stop() }
  }
}
