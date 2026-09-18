import SwiftUI

/// Shared by review tabs in the main window and independent task windows.
struct GitCommitPushView: View {
  @Bindable var store: WorkspaceStore
  @Bindable var workspace: DeveloperWorkspace
  var taskTitle: String? = nil
  @Environment(\.dismiss) private var dismiss
  @State private var choices: GitPushChoices?
  @State private var remote = ""
  @State private var destination = ""
  @State private var loading = true
  @State private var pushError: String?
  @State private var pushStatusLoading = false
  @State private var hasCommitsToPush = false
  @State private var pushStatusError: String?
  @State private var includeUnstaged = true
  @State private var createsBranch = false
  @State private var branchName = ""
  @State private var branchError: String?
  @State private var validatingBranch = false
  @State private var editedBranchName = false
  @State private var summaryLoader = GitCommitSummaryLoader()
  @State private var summaryRefresh = UUID()

  private var canCommit: Bool {
    workspace.canCommit && summaryLoader.request == summaryRequest
      && !summaryLoader.loading && summaryLoader.summary?.hasChanges == true
      && !workspace.gitRefreshing && !workspace.reviewLoading
      && (!createsBranch || (!validatingBranch && branchError == nil && !branchName.isEmpty))
  }
  private var performing: Bool { workspace.gitActionRunning }
  private var canPush: Bool {
    choices != nil && !destination.isEmpty && !loading && !pushStatusLoading && pushStatusError == nil
  }
  private var busy: Bool { performing || workspace.gitBusy || workspace.generatingCommitMessage }

  var body: some View {
    selectionAwareContent
      .interactiveDismissDisabled(busy)
      .task { await initialize() }
      .task(id: pushStatusKey) { await loadPushStatus() }
      .task(id: summaryRequest) { await summaryLoader.load(summaryRequest) }
      .onDisappear { workspace.cancelCommitMessageGeneration() }
  }

  private var selectionAwareContent: some View {
    dialogContent
      .task(id: branchValidationKey) { await validateBranch() }
      .onChange(of: includeUnstaged) { _, value in updateIncludeUnstaged(value) }
      .onChange(of: createsBranch) { _, value in updateBranchTarget(value) }
      .onChange(of: branchName) { old, value in
        if createsBranch && (destination == old || destination.isEmpty) { destination = value }
      }
      .onChange(of: taskTitle) { _, _ in updateSuggestedName() }
      .onChange(of: store.library.gitPreferences.branchPrefix) { _, _ in updateSuggestedName() }
      .onChange(of: workspace.reviewSnapshot) { _, _ in summaryRefresh = UUID() }
  }

  private var branchValidationKey: String { String(createsBranch) + "\0" + branchName }
  private var summaryRequest: GitCommitSummaryRequest {
    GitCommitSummaryRequest(root: workspace.root, includeUnstaged: includeUnstaged, revision: summaryRefresh)
  }
  private var pushStatusKey: String {
    remote + "\0" + destination + "\0" + String(store.library.gitPreferences.alwaysForcePush)
  }

  private var dialogContent: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("提交或推送").appFont(.title2)
        Spacer()
        Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
      }
      branchFields
      messageFields
      pushFields
      errorFields
      if performing { ProgressView(workspace.gitActionPhase).controlSize(.small) }
      Divider()
      actionButtons
    }.padding(24).frame(width: 510)
  }

  private func initialize() async {
    includeUnstaged = store.library.gitPreferences.includeUnstagedInCommit
    updateSuggestedName()
    createsBranch = workspace.gitBranch == "detached HEAD"
    await loadChoices()
  }

  private func updateSuggestedName() {
    guard !editedBranchName else { return }
    branchName = GitBranchSuggestion.name(prefix: store.library.gitPreferences.branchPrefix, title: taskTitle)
  }

  private func updateIncludeUnstaged(_ value: Bool) {
    workspace.cancelCommitMessageGeneration()
    guard value != store.library.gitPreferences.includeUnstagedInCommit else { return }
    var preferences = store.library.gitPreferences
    preferences.includeUnstagedInCommit = value
    if !store.saveGitPreferences(preferences) {
      workspace.error = store.error
      includeUnstaged = store.library.gitPreferences.includeUnstagedInCommit
    }
  }

  private func updateBranchTarget(_ value: Bool) {
    workspace.cancelCommitMessageGeneration()
    if value { destination = branchName }
    else if workspace.gitBranch == branchName { destination = branchName }
    else { destination = choices?.preferredDestination ?? workspace.gitBranch }
  }

  @ViewBuilder private var branchFields: some View {
      Picker("提交到", selection: $createsBranch) {
        Text(workspace.gitBranch).tag(false)
        Text("新分支").tag(true)
      }.disabled(busy)
      if createsBranch {
        TextField("新分支名称", text: Binding(get: { branchName }, set: {
          editedBranchName = true; branchName = $0
        })).disabled(busy)
        if validatingBranch { ProgressView("检查分支名称…").controlSize(.small) }
        else if let branchError { Text(branchError).appFont(.caption).foregroundStyle(.red) }
      }
  }

  @ViewBuilder private var messageFields: some View {
      Text("提交说明").appFont(.headline)
      TextEditor(text: $workspace.commitMessage)
        .frame(height: 100).border(.secondary.opacity(0.3))
        .accessibilityLabel("提交说明").disabled(performing)
      HStack {
        Text("留空时根据选中的变更自动生成。")
          .appFont(.caption).foregroundStyle(.secondary)
        Spacer()
        if workspace.generatingCommitMessage {
          Button("取消生成") { workspace.cancelCommitMessageGeneration() }
        } else {
          Button("生成提交说明") { store.generateCommitMessage(in: workspace, includeUnstaged: includeUnstaged) }
            .disabled(!canCommit || busy)
        }
      }
      HStack {
        Toggle("包含未暂存变更", isOn: $includeUnstaged).toggleStyle(.checkbox).disabled(busy)
        Spacer()
        selectionSummary
      }
  }

  @ViewBuilder private var selectionSummary: some View {
    if summaryLoader.request != summaryRequest || summaryLoader.loading {
      ProgressView().controlSize(.small).accessibilityLabel("正在读取所选变更")
    } else if let error = summaryLoader.error {
      Button("重试统计") { summaryRefresh = UUID() }.help(error).disabled(busy)
    } else if let summary = summaryLoader.summary {
      if summary.hasChanges {
        HStack(spacing: 5) {
          Text("+\(summary.additions)").foregroundStyle(.green)
          Text("−\(summary.deletions)").foregroundStyle(.red)
        }.appFont(.caption).monospacedDigit()
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("新增 \(summary.additions) 行，删除 \(summary.deletions) 行")
          .help("\(summary.files) 个文件；\(summary.binaryFiles) 个二进制文件")
      } else { Text("没有变更").appFont(.caption).foregroundStyle(.secondary) }
    }
  }

  @ViewBuilder private var pushFields: some View {
      if let choices {
        Picker("远端", selection: $remote) {
          ForEach(choices.remotes, id: \.self) { Text($0).tag($0) }
        }.disabled(busy)
        TextField("远端分支", text: $destination).disabled(busy)
        if store.library.gitPreferences.alwaysForcePush {
          Text("推送方式：--force-with-lease").appFont(.caption).foregroundStyle(.secondary)
        }
        if pushStatusLoading {
          ProgressView("读取推送状态…").controlSize(.small)
        } else if let pushStatusError {
          Text(pushStatusError).appFont(.caption).foregroundStyle(.orange)
          Button("刷新推送状态") { Task { await loadPushStatus() } }.disabled(busy)
        } else if !hasCommitsToPush {
          Text("没有可推送的新提交。").appFont(.caption).foregroundStyle(.secondary)
        }
      } else if loading {
        ProgressView("读取推送状态…").controlSize(.small)
      } else if let pushError {
        Text(pushError).appFont(.caption).foregroundStyle(.secondary)
        Button("重新读取") { Task { await loadChoices() } }.disabled(busy)
      }
  }

  @ViewBuilder private var errorFields: some View {
      if let error = workspace.error ?? workspace.commitGenerationError {
        if let status = workspace.gitActionStatus {
          Text(status).appFont(.caption).foregroundStyle(.secondary)
        }
        ScrollView { Text(error).appFont(.caption).foregroundStyle(.red).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 90)
      }
  }

  private var actionButtons: some View {
      HStack {
        Button("提交") { perform(commit: true, push: false) }.disabled(!canCommit || busy)
        Button("提交并推送") { perform(commit: true, push: true) }.disabled(!canCommit || !canPush || busy)
        Spacer()
        Button("推送") { perform(commit: false, push: true) }
          .disabled(!canPush || !hasCommitsToPush || busy || createsBranch)
      }.disabled(store.library.gitPreferences.readOnlyReview)
  }

  private func loadChoices() async {
    guard let root = workspace.root else { return }
    loading = true; pushError = nil
    defer { loading = false }
    do {
      let result = try await GitPushService.choices(at: root)
      guard !Task.isCancelled, workspace.root == root else { return }
      choices = result
      remote = result.preferredRemote
      destination = createsBranch ? branchName : result.preferredDestination
    } catch { if !Task.isCancelled { choices = nil; pushError = error.localizedDescription } }
  }

  private func perform(commit: Bool, push: Bool) {
    guard !busy, !store.library.gitPreferences.readOnlyReview, let root = workspace.root else { return }
    let selectedRemote = remote, selectedDestination = destination
    Task {
      let success = await store.performGitAction(commit ? (push ? .commitAndPush : .commit) : .push,
        in: workspace, remote: selectedRemote, destination: selectedDestination,
        includeUnstaged: includeUnstaged, newBranch: createsBranch ? branchName : nil)
      guard workspace.root == root else { return }
      if success { dismiss() }
      else {
        if createsBranch && workspace.gitBranch == branchName { createsBranch = false }
        // A commit may succeed even when its subsequent push fails.
        if let refreshed = try? await GitPushService.choices(at: root) {
          choices?.hasCommit = refreshed.hasCommit
        }
        await loadPushStatus()
      }
    }
  }

  private func validateBranch() async {
    guard createsBranch, let root = workspace.root else { return }
    validatingBranch = true; branchError = nil
    do {
      try await Task.sleep(for: .milliseconds(200))
      try await GitCommitSelection.validateBranch(branchName, at: root)
      try Task.checkCancellation()
    } catch {
      if !Task.isCancelled { branchError = error.localizedDescription }
    }
    if !Task.isCancelled { validatingBranch = false }
  }

  private func loadPushStatus() async {
    guard let root = workspace.root, let choices, !remote.isEmpty else { return }
    let selectedRemote = remote, selectedDestination = destination
    pushStatusLoading = true; hasCommitsToPush = false; pushStatusError = nil
    do {
      if choices.hasCommit {
        let plan = try await GitPushService.prepare(at: root, remote: selectedRemote,
          destination: selectedDestination, forceWithLease: store.library.gitPreferences.alwaysForcePush)
        try Task.checkCancellation()
        guard root == workspace.root, selectedRemote == remote, selectedDestination == destination else { return }
        if plan.expectedRemoteCommit.isEmpty { hasCommitsToPush = true }
        else {
          let count = try await GitReviewService.checked(
            ["rev-list", "--count", plan.expectedRemoteCommit + ".." + plan.commit], at: root)
          try Task.checkCancellation()
          guard root == workspace.root, selectedRemote == remote,
            selectedDestination == destination else { return }
          hasCommitsToPush = (Int(count.trimmingCharacters(in: .newlines)) ?? 0) > 0
        }
      }
    } catch {
      if !Task.isCancelled, root == workspace.root, selectedRemote == remote,
        selectedDestination == destination { pushStatusError = error.localizedDescription }
    }
    if !Task.isCancelled, root == workspace.root, selectedRemote == remote,
      selectedDestination == destination { pushStatusLoading = false }
  }
}
