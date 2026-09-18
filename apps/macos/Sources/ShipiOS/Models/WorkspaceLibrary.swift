import Foundation

struct WorkspaceTask: Codable, Identifiable, Equatable {
  var id: String
  var project: String
  var title: String
  var runIDs: [String]
  var pinned = false
  var archived = false
  var archivedAt: Date?
  var forkOrigin: ConversationForkOrigin?
  var modelSelection: TaskModelSelection?
  /// Present only while a newly opened task window has not submitted its first message.
  var popoutDraft: Bool?
  var createdAt: Date?
  var updatedAt: Date?

  mutating func includeDates(from run: AgentRun) {
    if run.createdAt.isFinite, forkOrigin == nil || createdAt == nil {
      let date = Date(timeIntervalSince1970: run.createdAt / 1000)
      createdAt = min(createdAt ?? date, date)
    }
    if run.updatedAt.isFinite {
      let date = Date(timeIntervalSince1970: run.updatedAt / 1000)
      updatedAt = max(updatedAt ?? date, date)
    }
  }

  var isPopoutDraft: Bool { popoutDraft == true }
  var selectionID: String { runIDs.last ?? id }
}

struct BuildProfile: Codable {
  var container = ""
  var scheme = ""
  var configuration = "Debug"
}

enum ReviewDelivery: String, Codable, CaseIterable, Identifiable, Sendable {
  case inline, detached

  var id: String { rawValue }
  var title: String {
    switch self {
    case .inline: "内联"
    case .detached: "单独"
    }
  }
}

struct GitPreferences: Codable, Equatable {
  var branchPrefix = "codex/"
  var defaultReviewScope = GitReviewScope.unstaged
  var readOnlyReview = false
  var reviewDelivery = ReviewDelivery.inline
  var commitInstructions = ""
  var pullRequestInstructions = ""
  var alwaysForcePush = false
  var includeUnstagedInCommit = true
  var createDraftPullRequests = false

  init() {}

  enum CodingKeys: String, CodingKey {
    case branchPrefix, defaultReviewScope, readOnlyReview, reviewDelivery, commitInstructions, alwaysForcePush
    case includeUnstagedInCommit
    case createDraftPullRequests
    case pullRequestInstructions
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    branchPrefix = try c.decodeIfPresent(String.self, forKey: .branchPrefix) ?? "codex/"
    defaultReviewScope =
      try c.decodeIfPresent(GitReviewScope.self, forKey: .defaultReviewScope) ?? .unstaged
    readOnlyReview = try c.decodeIfPresent(Bool.self, forKey: .readOnlyReview) ?? false
    reviewDelivery =
      try c.decodeIfPresent(ReviewDelivery.self, forKey: .reviewDelivery) ?? .inline
    commitInstructions = try c.decodeIfPresent(String.self, forKey: .commitInstructions) ?? ""
    pullRequestInstructions = try c.decodeIfPresent(String.self, forKey: .pullRequestInstructions) ?? ""
    alwaysForcePush = try c.decodeIfPresent(Bool.self, forKey: .alwaysForcePush) ?? false
    includeUnstagedInCommit = try c.decodeIfPresent(Bool.self, forKey: .includeUnstagedInCommit) ?? true
    createDraftPullRequests = try c.decodeIfPresent(Bool.self, forKey: .createDraftPullRequests) ?? false
  }

  mutating func normalize() {
    branchPrefix = branchPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
    while branchPrefix.hasPrefix("/") { branchPrefix.removeFirst() }
    if !branchPrefix.isEmpty, !branchPrefix.hasSuffix("/") { branchPrefix += "/" }
  }
}

enum FollowUpBehavior: String, Codable, CaseIterable, Identifiable {
  case steer
  case queue

  var id: String { rawValue }
  var title: String {
    switch self {
    case .steer: "引导当前运行"
    case .queue: "等待下一轮"
    }
  }
  var explanation: String {
    switch self {
    case .steer: "停止当前模型请求，并将已生成的部分回答作为上下文立即继续。"
    case .queue: "让当前回复完成，再按顺序自动发送追加消息。停止或失败时消息仍保留。"
    }
  }
  var composerLabel: String {
    switch self {
    case .steer: "引导当前运行"
    case .queue: "加入队列"
    }
  }
}

enum WebLinkTarget: String, Codable, CaseIterable, Identifiable {
  case inAppBrowser
  case externalBrowser

  var id: String { rawValue }
  var title: String {
    switch self {
    case .inAppBrowser: "应用内浏览器"
    case .externalBrowser: "系统默认浏览器"
    }
  }
}

/// Desktop organization is separate from immutable execution records in the Agent database.
struct WorkspaceLibrary: Codable {
  var tasks: [WorkspaceTask] = []
  var projects: [String] = []
  /// nil migrates legacy selection; empty string is an explicit projectless workspace.
  var lastWorkspace: String?
  var chatRuns: [AgentRun] = []
  var forkRuns: [AgentRun] = []
  var forkRunOrigins: [String: String] = [:]
  /// Immutable Agent audit rows can outlive the desktop task. Tombstones keep deleted tasks deleted.
  var deletedRunIDs: Set<String> = []
  var localRuns: [AgentRun] { chatRuns + forkRuns }
  var queuedMessages: [QueuedMessage] = []
  var notes: [String: String] = [:]
  var runBranches: [String: String] = [:]
  var drafts: [String: String] = [:]
  var draftImages: [String: [ImageAttachment]] = [:]
  var runImages: [String: [ImageAttachment]] = [:]
  var draftFiles: [String: [FileAttachment]] = [:]
  var runFiles: [String: [FileAttachment]] = [:]
  var fileReferences: [UUID: FileAttachment] {
    Dictionary((Array(draftFiles.values).flatMap { $0 } + Array(runFiles.values).flatMap { $0 }
      + queuedMessages.flatMap(\.files)).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }
  var imageReferences: [UUID: ImageAttachment] {
    Dictionary((Array(draftImages.values).flatMap { $0 } + Array(runImages.values).flatMap { $0 }
      + queuedMessages.flatMap(\.images)).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }
  var profiles: [String: BuildProfile] = [:]
  var projectNames: [String: String] = [:]
  var pinnedProjects: Set<String> = []
  var pinnedContentTabs: [PinnedWorkspaceTab] = []
  var unreadTasks: Set<String> = []
  var recentTaskIDs: [String] = []
  var collapsedProjects: Set<String> = []
  /// Empty string explicitly remembers a new, unsent task.
  var projectSelections: [String: String] = [:]
  var sidebar = SidebarLayout()
  var panelSizes: [String: WorkspacePanelSizes] = [:]
  var reviewComments: [String: [ReviewComment]] = [:]
  var browserComments: [String: [BrowserComment]] = [:]
  var preferredEditor = ExternalEditor.system.rawValue
  var appearance: AppearancePreferences?
  var notifications: CompletionNotificationPreferences?
  var preventIdleSleep = false
  var followUpBehavior = FollowUpBehavior.queue
  var browserHistory: [BrowserHistoryEntry] = []
  var browserPermissions = BrowserPermissionPreferences()
  var browserDownloadPreferences = BrowserDownloadPreferences()
  var browserDownloads: [BrowserDownloadRecord] = []
  var pluginsEnabled = true
  var showInMenuBar = true
  var showEducationalTips = true
  var dismissedEducationalTipIDs: Set<String> = []
  var showContextUsageIndicator = false
  var showBottomPanelControl = true
  var composerPlainTextMode = false
  var webLinkTarget = WebLinkTarget.inAppBrowser
  var projectlessWorkspaceRoot: String?
  var projectlessTaskDirectories: [String: String] = [:]
  var popoutWindowProjectlessDefault = false
  var defaultTerminalLocation = WorkspaceTabPlacement.bottom
  var gitPreferences = GitPreferences()
  var worktreeRoot: String?
  var permanentWorktrees: [PermanentWorktree] = []
  var goalSessions: [String: GoalSession] = [:]

  init() {}
  enum CodingKeys: String, CodingKey {
    case tasks, projects, lastWorkspace, notes, runBranches, drafts, draftImages, runImages, draftFiles, runFiles, profiles, chatRuns, queuedMessages, projectNames,
      pinnedProjects, pinnedContentTabs, unreadTasks, recentTaskIDs, collapsedProjects, projectSelections, sidebar, panelSizes,
      reviewComments, browserComments, preferredEditor, appearance, forkRuns, forkRunOrigins, deletedRunIDs, notifications, preventIdleSleep,
      followUpBehavior, browserHistory, browserPermissions, browserDownloadPreferences,
      browserDownloads,
      pluginsEnabled, showInMenuBar, showEducationalTips, dismissedEducationalTipIDs,
      showContextUsageIndicator, showBottomPanelControl, composerPlainTextMode,
      webLinkTarget, projectlessWorkspaceRoot, projectlessTaskDirectories,
      popoutWindowProjectlessDefault,
      defaultTerminalLocation, gitPreferences,
      worktreeRoot, permanentWorktrees, goalSessions
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    queuedMessages = try c.decodeIfPresent([QueuedMessage].self, forKey: .queuedMessages) ?? []
    chatRuns = try c.decodeIfPresent([AgentRun].self, forKey: .chatRuns) ?? []
    forkRuns = try c.decodeIfPresent([AgentRun].self, forKey: .forkRuns) ?? []
    forkRunOrigins = try c.decodeIfPresent([String: String].self, forKey: .forkRunOrigins) ?? [:]
    deletedRunIDs = try c.decodeIfPresent(Set<String>.self, forKey: .deletedRunIDs) ?? []
    tasks = try c.decodeIfPresent([WorkspaceTask].self, forKey: .tasks) ?? []
    lastWorkspace = try c.decodeIfPresent(String.self, forKey: .lastWorkspace)
    projects = try c.decodeIfPresent([String].self, forKey: .projects) ?? []
    notes = try c.decodeIfPresent([String: String].self, forKey: .notes) ?? [:]
    runBranches = try c.decodeIfPresent([String: String].self, forKey: .runBranches) ?? [:]
    draftImages = try c.decodeIfPresent([String: [ImageAttachment]].self, forKey: .draftImages) ?? [:]
    runImages = try c.decodeIfPresent([String: [ImageAttachment]].self, forKey: .runImages) ?? [:]
    draftFiles = try c.decodeIfPresent([String: [FileAttachment]].self, forKey: .draftFiles) ?? [:]
    runFiles = try c.decodeIfPresent([String: [FileAttachment]].self, forKey: .runFiles) ?? [:]
    drafts = try c.decodeIfPresent([String: String].self, forKey: .drafts) ?? [:]
    profiles = try c.decodeIfPresent([String: BuildProfile].self, forKey: .profiles) ?? [:]
    projectNames = try c.decodeIfPresent([String: String].self, forKey: .projectNames) ?? [:]
    pinnedProjects = try c.decodeIfPresent(Set<String>.self, forKey: .pinnedProjects) ?? []
    pinnedContentTabs =
      try c.decodeIfPresent([PinnedWorkspaceTab].self, forKey: .pinnedContentTabs) ?? []
    unreadTasks = try c.decodeIfPresent(Set<String>.self, forKey: .unreadTasks) ?? []
    recentTaskIDs = try c.decodeIfPresent([String].self, forKey: .recentTaskIDs) ?? []
    collapsedProjects = try c.decodeIfPresent(Set<String>.self, forKey: .collapsedProjects) ?? []
    projectSelections =
      try c.decodeIfPresent([String: String].self, forKey: .projectSelections) ?? [:]
    sidebar = try c.decodeIfPresent(SidebarLayout.self, forKey: .sidebar) ?? SidebarLayout()
    panelSizes =
      try c.decodeIfPresent([String: WorkspacePanelSizes].self, forKey: .panelSizes) ?? [:]
    reviewComments =
      try c.decodeIfPresent([String: [ReviewComment]].self, forKey: .reviewComments) ?? [:]
    browserComments =
      try c.decodeIfPresent([String: [BrowserComment]].self, forKey: .browserComments) ?? [:]
    preferredEditor =
      try c.decodeIfPresent(String.self, forKey: .preferredEditor) ?? ExternalEditor.system.rawValue
    appearance = try c.decodeIfPresent(AppearancePreferences.self, forKey: .appearance)?
      .normalized()
    notifications = try c.decodeIfPresent(CompletionNotificationPreferences.self, forKey: .notifications)
    preventIdleSleep = try c.decodeIfPresent(Bool.self, forKey: .preventIdleSleep) ?? false
    followUpBehavior = try c.decodeIfPresent(FollowUpBehavior.self, forKey: .followUpBehavior) ?? .queue
    browserHistory = try c.decodeIfPresent([BrowserHistoryEntry].self, forKey: .browserHistory) ?? []
    browserPermissions =
      try c.decodeIfPresent(BrowserPermissionPreferences.self, forKey: .browserPermissions)
      ?? BrowserPermissionPreferences()
    browserDownloadPreferences =
      try c.decodeIfPresent(BrowserDownloadPreferences.self, forKey: .browserDownloadPreferences)
      ?? BrowserDownloadPreferences()
    browserDownloads =
      try c.decodeIfPresent([BrowserDownloadRecord].self, forKey: .browserDownloads) ?? []
    pluginsEnabled = try c.decodeIfPresent(Bool.self, forKey: .pluginsEnabled) ?? true
    showInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showInMenuBar) ?? true
    showEducationalTips =
      try c.decodeIfPresent(Bool.self, forKey: .showEducationalTips) ?? true
    dismissedEducationalTipIDs =
      try c.decodeIfPresent(Set<String>.self, forKey: .dismissedEducationalTipIDs) ?? []
    showContextUsageIndicator =
      try c.decodeIfPresent(Bool.self, forKey: .showContextUsageIndicator) ?? false
    showBottomPanelControl =
      try c.decodeIfPresent(Bool.self, forKey: .showBottomPanelControl) ?? true
    composerPlainTextMode =
      try c.decodeIfPresent(Bool.self, forKey: .composerPlainTextMode) ?? false
    webLinkTarget =
      try c.decodeIfPresent(WebLinkTarget.self, forKey: .webLinkTarget) ?? .inAppBrowser
    projectlessWorkspaceRoot =
      try c.decodeIfPresent(String.self, forKey: .projectlessWorkspaceRoot)
    projectlessTaskDirectories =
      try c.decodeIfPresent([String: String].self, forKey: .projectlessTaskDirectories) ?? [:]
    popoutWindowProjectlessDefault =
      try c.decodeIfPresent(Bool.self, forKey: .popoutWindowProjectlessDefault) ?? false
    defaultTerminalLocation =
      try c.decodeIfPresent(WorkspaceTabPlacement.self, forKey: .defaultTerminalLocation) ?? .bottom
    if defaultTerminalLocation != .right && defaultTerminalLocation != .bottom {
      defaultTerminalLocation = .bottom
    }
    gitPreferences = try c.decodeIfPresent(GitPreferences.self, forKey: .gitPreferences) ?? GitPreferences()
    gitPreferences.normalize()
    worktreeRoot = try c.decodeIfPresent(String.self, forKey: .worktreeRoot)
    permanentWorktrees = try c.decodeIfPresent([PermanentWorktree].self, forKey: .permanentWorktrees) ?? []
    goalSessions = try c.decodeIfPresent([String: GoalSession].self, forKey: .goalSessions) ?? [:]
  }
  func projectTitle(_ path: String) -> String {
    path.isEmpty ? "无项目" : (projectNames[path] ?? URL(fileURLWithPath: path).lastPathComponent)
  }

  func isPermanentWorktree(_ path: String) -> Bool {
    permanentWorktrees.contains { $0.path == path && $0.ready }
  }

  var orderedProjects: [String] {
    ([SidebarLayout.pinned] + sidebar.groups.map(\.id) + [SidebarLayout.projects]).flatMap {
      sidebarItems(in: $0).compactMap { item in
        if case .project(let path) = item { return path }
        return nil
      }
    }
  }

  func rememberedSelection(project: String) -> String? {
    if let saved = projectSelections[project] {
      if saved.isEmpty { return nil }
      if tasks.contains(where: {
        $0.project == project && !$0.archived
          && ($0.runIDs.contains(saved) || (!$0.isPopoutDraft && $0.runIDs.isEmpty && $0.id == saved))
      }) {
        return saved
      }
    }
    return visible(project: project, query: "", archived: false).first?.selectionID
  }

  mutating func visit(_ project: String) {
    projects.removeAll { $0 == project }
    projects.insert(project, at: 0)
  }

  mutating func reconcile(_ runs: [AgentRun], project: String) {
    let byID = Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    for index in tasks.indices where tasks[index].project == project {
      for id in tasks[index].runIDs {
        if let run = byID[id] { tasks[index].includeDates(from: run) }
      }
    }
    let known = Set(tasks.filter { $0.project == project }.flatMap(\.runIDs))
    for run in runs.reversed() where !known.contains(run.id) && !deletedRunIDs.contains(run.id) {
      tasks.insert(
        WorkspaceTask(id: run.id, project: project, title: run.title, runIDs: [run.id]), at: 0)
      tasks[0].includeDates(from: run)
    }
  }

  mutating func attach(_ run: AgentRun, to taskID: String?, note: String) {
    guard !deletedRunIDs.contains(run.id) else { return }
    // An event may import this run before the run.start response reaches the UI.
    tasks.removeAll { $0.id == run.id && $0.runIDs == [run.id] && $0.id != taskID }
    notes[run.id] = note
    if let index = tasks.firstIndex(where: { $0.id == taskID && $0.project == run.project }) {
      let wasUnsubmitted = tasks[index].runIDs.isEmpty
      if !tasks[index].runIDs.contains(run.id) { tasks[index].runIDs.append(run.id) }
      if tasks[index].isPopoutDraft || wasUnsubmitted {
        tasks[index].title = note.isEmpty ? run.title : String(note.prefix(80))
        tasks[index].popoutDraft = nil
      }
      tasks[index].archived = false
      tasks[index].archivedAt = nil
      tasks[index].includeDates(from: run)
      let task = tasks.remove(at: index)
      tasks.insert(task, at: 0)
    } else {
      tasks.insert(
        WorkspaceTask(
          id: run.id, project: run.project,
          title: note.isEmpty ? run.title : String(note.prefix(80)), runIDs: [run.id]), at: 0)
      tasks[0].includeDates(from: run)
    }
  }

  @discardableResult mutating func deleteArchivedTasks(_ taskIDs: Set<String>) -> Set<String> {
    let deletedTasks = tasks.filter { taskIDs.contains($0.id) && $0.archived }
    let deletedTaskIDs = Set(deletedTasks.map(\.id))
    let runIDs = Set(deletedTasks.flatMap(\.runIDs))
    guard !deletedTaskIDs.isEmpty else { return [] }

    tasks.removeAll { deletedTaskIDs.contains($0.id) }
    for index in tasks.indices where deletedTaskIDs.contains(tasks[index].forkOrigin?.taskID ?? "") {
      tasks[index].forkOrigin = nil
    }
    deletedRunIDs.formUnion(runIDs)
    chatRuns.removeAll { runIDs.contains($0.id) }
    forkRuns.removeAll { runIDs.contains($0.id) }
    forkRunOrigins = forkRunOrigins.filter { !runIDs.contains($0.key) }
    queuedMessages.removeAll { deletedTaskIDs.contains($0.taskID) }
    unreadTasks.subtract(deletedTaskIDs)
    recentTaskIDs.removeAll { deletedTaskIDs.contains($0) }

    for id in runIDs {
      notes[id] = nil
      runBranches[id] = nil
      runImages[id] = nil
      runFiles[id] = nil
    }
    for id in deletedTaskIDs {
      goalSessions[id] = nil
      projectlessTaskDirectories[id] = nil
      drafts[id] = nil
      draftImages[id] = nil
      draftFiles[id] = nil
      reviewComments[id] = nil
      browserComments[id] = nil
      let sidebarID = SidebarItem.task(id).id
      sidebar.placement[sidebarID] = nil
      for section in Array(sidebar.order.keys) {
        sidebar.order[section]?.removeAll { $0 == sidebarID }
      }
    }
    projectSelections = projectSelections.filter {
      !runIDs.contains($0.value) && !deletedTaskIDs.contains($0.value)
    }
    return runIDs
  }

  func task(containing runID: String?) -> WorkspaceTask? {
    guard let runID else { return nil }
    return tasks.first {
      $0.runIDs.contains(runID) || (!$0.isPopoutDraft && $0.runIDs.isEmpty && $0.id == runID)
    }
  }

  func visible(project: String, query: String, archived: Bool) -> [WorkspaceTask] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return tasks.filter {
      !$0.isPopoutDraft && $0.project == project && $0.archived == archived
        && (query.isEmpty
          || $0.title.localizedCaseInsensitiveContains(query)
          || $0.runIDs.contains { notes[$0]?.localizedCaseInsensitiveContains(query) == true })
    }
  }

  static func load(from url: URL) throws -> Self {
    guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
    return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
  }

  func save(to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(self).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

enum LocalAction: String, CaseIterable, Identifiable {
  case chat, doctor, build
  var id: String { rawValue }
  var title: String { self == .chat ? "模型会话" : self == .doctor ? "环境诊断" : "构建项目" }
  var icon: String { self == .chat ? "sparkle" : self == .doctor ? "stethoscope" : "hammer" }

  static func parse(_ text: String, fallback: Self) throws -> (Self, String) {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.hasPrefix("/") else { return (fallback, text) }
    let pieces = text.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
    guard let first = pieces.first, let action = Self(rawValue: String(first.dropFirst())) else {
      throw AgentFailure(message: "支持 /chat、/doctor 和 /build。请选择下方的操作模式。")
    }
    return (action, pieces.count > 1 ? String(pieces[1]) : "")
  }
}

enum ChatMode: String, Codable, Equatable, Sendable {
  case standard, plan, goal

  var title: String {
    switch self {
    case .standard: "标准"
    case .plan: "计划"
    case .goal: "目标"
    }
  }
  var icon: String {
    switch self {
    case .standard: "sparkle"
    case .plan: "list.bullet.clipboard"
    case .goal: "target"
    }
  }
}

struct GoalDefinition: Codable, Equatable, Sendable {
  var objective: String
  var successCriteria: [String]
  var maxIterations: Int = 5

  var normalized: GoalDefinition {
    GoalDefinition(
      objective: objective.trimmingCharacters(in: .whitespacesAndNewlines),
      successCriteria: successCriteria.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty },
      maxIterations: min(max(maxIterations, 1), 10))
  }
}

enum GoalStatus: String, Codable, Equatable, Sendable {
  case active, paused, completed

  var title: String {
    switch self {
    case .active: "进行中"
    case .paused: "已暂停"
    case .completed: "已完成"
    }
  }
}

struct GoalSession: Codable, Equatable, Sendable {
  var definition: GoalDefinition
  var status: GoalStatus = .active
  var iteration = 0
  var lastRunID: String?
}

struct QueuedMessage: Codable, Identifiable, Equatable {
  var id = UUID()
  let taskID: String
  var text: String
  var images: [ImageAttachment] = []
  var files: [FileAttachment] = []
  var mode: ChatMode = .standard
  enum CodingKeys: String, CodingKey { case id, taskID, text, images, files, mode }
  init(
    taskID: String, text: String, images: [ImageAttachment] = [], files: [FileAttachment] = [],
    mode: ChatMode = .standard
  ) {
    self.taskID = taskID; self.text = text; self.images = images; self.files = files
    self.mode = mode
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    taskID = try c.decode(String.self, forKey: .taskID)
    text = try c.decode(String.self, forKey: .text)
    images = try c.decodeIfPresent([ImageAttachment].self, forKey: .images) ?? []
    files = try c.decodeIfPresent([FileAttachment].self, forKey: .files) ?? []
    mode = try c.decodeIfPresent(ChatMode.self, forKey: .mode) ?? .standard
  }
}
