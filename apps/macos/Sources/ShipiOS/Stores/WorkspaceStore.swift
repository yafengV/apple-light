import AppKit
import CryptoKit
import Observation
import UniformTypeIdentifiers
import WebKit

@MainActor @Observable
final class WorkspaceStore {
  var library = WorkspaceLibrary() {
    didSet {
      synchronizeActivityPriority()
      if oldValue.projectAdditionalFolders != library.projectAdditionalFolders
        || oldValue.projectPrimaryFolders != library.projectPrimaryFolders
        || oldValue.projectScopeOwners != library.projectScopeOwners {
        synchronizeWorkspaceFileRoots()
      }
    }
  }
  var dictation = SpeechDictation()
  let realtimeVoice = RealtimeVoiceSession()
  let systemAudioVisualizer = SystemAudioVisualizer()
  var voiceChatPresented = false
  let voiceRecordingHistory: VoiceRecordingHistory
  @ObservationIgnored var globalDictationHotkeyChangeHandler: (() -> Void)?
  @ObservationIgnored var voiceHotkeyPreferenceCommitHandler:
    ((VoicePreferences, VoicePreferences, () throws -> Void) throws -> Void)?
  @ObservationIgnored var voiceHotkeyRegistrationRetryHandler: ((VoiceShortcutPresentation.Mode) -> Void)?
  @ObservationIgnored weak var voiceRegistrationController: VoiceHotkeyRegistrationController?
  var voiceShortcutRegistrationErrors: [VoiceShortcutPresentation.Mode: String] = [:]
  var globalDictationHotkeyError: String?
  var globalVoiceChatHotkeyError: String?
  @ObservationIgnored let appshotCapture = AppshotCapture()
  @ObservationIgnored var appshotHotkeyChangeHandler: (() -> Void)?
  var appshotHotkeyError: String?
  var pendingAppshot: PendingAppshot?
  var appshotIntroRequest: AppshotIntroRequest?
  var appshotHandoff: AppshotHandoff?
  @ObservationIgnored let appshotHandoffAnimator = AppshotHandoffAnimator()
  @ObservationIgnored let prCodePresentationCache = GitHubPRCodePresentationCache()
  @ObservationIgnored var appshotHandoffStarted = false
  @ObservationIgnored var dictationCarets: [String: DictationCaret] = [:]
  var shortcuts: ShortcutPreferences
  @ObservationIgnored var shortcutCaptureCount = 0
  @ObservationIgnored var popoutWindowHandler: (() -> Void)?
  @ObservationIgnored var popoutWindowToggleHandler: (() -> Void)?
  @ObservationIgnored var showMainWindowHandler: (() -> Void)?
  var popoutHotkeyError: String? {
    get { shortcuts.globalRegistrationErrors["popout"] }
    set { shortcuts.globalRegistrationErrors["popout"] = newValue }
  }
  @ObservationIgnored private let root: URL
  @ObservationIgnored private let agentExecutable: URL?
  @ObservationIgnored let browserDataStore: WKWebsiteDataStore?
  var query = ""
  var presentedOverlay: WorkspaceOverlay?
  var projectPickerCreatesNewTask = false
  @ObservationIgnored var searchDialogReturnFocus: SearchDialogReturnFocus?
  @ObservationIgnored var searchDialogFocusRevision = UUID()
  var fileFocusAfterOverlay: (root: URL, path: String)?
  var showingSearch: Bool {
    get { presentedOverlay == .taskSearch }
    set { setOverlay(.taskSearch, presented: newValue) }
  }
  var showingCommands: Bool {
    get { presentedOverlay == .commands }
    set { setOverlay(.commands, presented: newValue) }
  }
  var destination: AppDestination = .workspace {
    didSet {
      if oldValue != destination {
        environmentSettingsNavigationRevision = UUID()
        worktreeForkPresentation.dismiss()
      }
      if destination != .settings, let session = appearanceThemeImport {
        dismissAppearanceImport(session)
      }
    }
  }
  var activityError: String?
  var activityOpeningTaskID: String?
  var activityArchiveRequest: ActivityArchiveRequest?
  var activityArchiveResult: ActivityArchiveResult?
  var archivingActivity = false
  var activityArchivingTaskIDs: Set<String> = []
  var taskMenuForkingID: String?
  var activitySession: ActivitySession?
  var showingActivity: Bool { activitySession != nil }
  var taskWindowOpenRequest: TaskWindowRoute?
  var taskSummaryToggleRequest = UUID()
  var showingTaskStatus = false
  var settingsReturnDestination: AppDestination = .workspace
  @ObservationIgnored var settingsReturnFocus: SettingsReturnFocus?
  @ObservationIgnored var settingsFocusRevision = UUID()
  var showingFileSearch: Bool {
    get { presentedOverlay == .fileSearch }
    set { setOverlay(.fileSearch, presented: newValue) }
  }
  var showingTerminal = false
  var terminalFocusRequest: TerminalFocusRequest?
  var showingFind = false
  var findText = ""
  var findIndex = 0
  var findRequest = UUID()
  var findMatches: [ConversationMatch] = []
  var finding = false
  @ObservationIgnored var findGeneration = UUID()
  @ObservationIgnored var indexedFindText = ""
  @ObservationIgnored var indexedFindTask: String?
  var renameTaskID: String?
  var pinnedBrowserRenameRequest: PinnedBrowserRenameRequest?
  var pinnedBrowserRenameReturnPinID: String?
  var pinnedBrowserRenameReturnFocus = UUID()
  var renameProjectPath: String?
  var editingProject: ProjectEditRequest?
  var renameDraft = ""
  var sidebarGroupEditor: SidebarGroupEditor?
  var sidebarGroupDraft = ""
  var sidebarGroupToDelete: SidebarGroup?
  var settingsPage: SettingsPage = .general {
    didSet {
      if oldValue != settingsPage { environmentSettingsNavigationRevision = UUID() }
      if settingsPage != .general { showingOpenSourceLicenses = false }
      if settingsPage != .appearance, let session = appearanceThemeImport {
        dismissAppearanceImport(session)
      }
      if oldValue != settingsPage { pluginDetailForwardRoute = nil }
      if let section = settingsPage.pluginSection {
        pluginSettingsSection = section
        settingsPage = .plugins
      }
      if settingsSearchRequest?.result.page != settingsPage { settingsSearchRequest = nil }
      mcpServerEditor = nil
    }
  }
  var showingOpenSourceLicenses = false
  var modelSettingsDirty = false
  var modelSettingsResetRequest = UUID()
  var pendingSettingsNavigation: PendingSettingsNavigation?
  var settingsSearchRequest: SettingsSearchRequest?
  var settingsSearchFocusRequest = UUID()
  var settingsLastControlFocusRequest = UUID()
  var pluginDetailRoute: PluginDetailRoute?
  var pluginDetailForwardRoute: PluginDetailRoute?
  var pluginSettingsSection = PluginSettingsSection.plugins {
    didSet {
      if let target = settingsSearchRequest?.result.field?.pluginSection,
        target != pluginSettingsSection { settingsSearchRequest = nil }
    }
  }
  var pluginSettingsQuery = "" {
    didSet {
      if !pluginSettingsQuery.isEmpty, settingsSearchRequest?.result.field?.pluginSection != nil {
        settingsSearchRequest = nil
      }
    }
  }
  var browserSettingsSection = BrowserSettingsSection.history {
    didSet {
      if let target = settingsSearchRequest?.result.field?.browserSection,
        target != browserSettingsSection { settingsSearchRequest = nil }
    }
  }
  var connectionSettingsSection = ConnectionSettingsSection.ssh {
    didSet {
      if let target = settingsSearchRequest?.result.field?.connectionSection,
        target != connectionSettingsSection { settingsSearchRequest = nil }
    }
  }
  var pane = "execution"
  let pullRequestTabPresentations = PullRequestTabPresentations()
  var workspaceTabs: [WorkspaceContentTab] = []
  @ObservationIgnored var workspaceTabCloseControllers: [ContentTabCloseScope: ContentTabCloseController] = [:]
  @ObservationIgnored var synchronizingWorkspaceBrowserSelection = false
  @ObservationIgnored var pendingWorkspaceTabCloses: [String: UUID] = [:]
  @ObservationIgnored var workspaceLayoutActiveOwner: String?
  @ObservationIgnored var restoredWorkspaceTabOwners: Set<String> = []
  @ObservationIgnored var restoringWorkspaceTabLayout = false
  var restoredDetachedWorkspaceTabIDs: [String] = []
  var workspaceTabPlacements: [String: WorkspaceTabPlacement] = [:]
  var activeWorkspaceTabID: String?
  var workspaceContentLayoutMode: WorkspaceContentLayoutMode?
  var workspaceContentRightToLeft = false
  var activeRightWorkspaceTabID: String?
  var activeBottomWorkspaceTabID: String?
  var focusedWorkspaceTabID: String?
  var draggingWorkspaceTabID: String?
  var workspaceTabDropTarget: WorkspaceTabDropTarget?
  var workspaceTabDragSessionID: UUID?
  var showingWorkspaceTabs = true
  var workspaceContentPaneSide: WorkspacePaneSide = .right
  var lastWorkspaceContentTabID: String?
  var closedWorkspaceTabs: [WorkspaceContentTab] = []
  var closedFilePlacements: [String: WorkspaceTabPlacement] = [:]
  var closedPullRequestPlacements: [String: WorkspaceTabPlacement] = [:]
  @ObservationIgnored var reopeningWorkspaceTabOwner: String?
  var workspace = DeveloperWorkspace()
  @ObservationIgnored var fileTabWorkspaces: [String: DeveloperWorkspace] = [:]
  @ObservationIgnored var pendingFileEditorRecoveryWorkspaces: [ObjectIdentifier: DeveloperWorkspace] = [:]
  @ObservationIgnored var fileEditorRecoveryError: String?
  @ObservationIgnored var workspaceFileTabRoots: [String: URL] = [:]
  @ObservationIgnored var legacyReviewFileRoots: [String: URL] = [:]
  var navigationBack: [TaskLocation] = []
  var navigationForward: [TaskLocation] = []
  var navigatingWorkspaceHistory = false
  var showingArchived = false
  var showingInspector = false
  var inspectorTab = "diagnostics"
  var action: LocalAction = .chat
  var chatMode: ChatMode = .standard
  var pendingGoal: GoalDefinition?
  var showingGoalEditor = false
  var showingReviewMode = false
  var reviewModeBranches: [GitReviewChoice] = []
  var reviewModeLoading = false
  var reviewModeStarting = false
  var reviewModeError: String?
  var reviewModeProject: String?
  var modelConfiguration = ModelConfiguration()
  var modelCatalogRevision = UUID()
  @ObservationIgnored var skillModelCatalogs: [ModelCatalogSource: [String: ModelCatalogEntry]] = [:]
  @ObservationIgnored var skillModelCatalogGenerations: [ModelCatalogSource: UUID] = [:]
  var personalization = Personalization()
  var customInstructions = ""
  var personalizationDraft = ""
  var personalizationError: String?
  var personalizationLoaded = false
  var personalizationLoading = false
  var memoryPreferences = MemoryPreferences()
  var memoryDraft = ""
  var memoryError: String?
  var memoriesLoaded = false
  var memoriesLoading = false
  var profile = ProfilePreferences()
  var profileNameDraft = ""
  var profileUsernameDraft = ""
  var profileError: String?
  var profileLoaded = false
  var profileLoading = false
  var profileAvatarVersion = UUID()
  var confettiBurst: UUID?
  var petPreferences = PetPreferences()
  var petCustomData: Data?
  var petError: String?
  var petsLoaded = false
  var petsLoading = false
  var petAssetVersion = UUID()
  @ObservationIgnored var petPanelHandler: ((PetPreferences) -> Void)?
  var pluginPreferences = PluginPreferences() {
    didSet { reconcilePluginSettingsTarget() }
  }
  var pluginSkills: [PluginSkillReference] = []
  var installedPluginSkills: [PluginSkillReference] = []
  @ObservationIgnored var repositorySkillCache: [String: [PluginSkillReference]] = [:]
  @ObservationIgnored var skillSourceFingerprint: String?
  @ObservationIgnored var checkingSkillSources = false
  var repositorySkillRevision = UUID()
  var skillLibraryQuery = ""
  var skillTrialInProgress = false
  var pluginsLoaded = false
  var pluginsLoading = false
  var pluginsError: String?
  var hookSettings: HookSettingsState
  var mcpServers: [MCPServerConfiguration] = []
  var mcpServersLoaded = false
  var mcpServersLoading = false
  var mcpServersError: String?
  var mcpServerEditor: MCPServerConfiguration?
  var mcpConnectionStates: [UUID: MCPConnectionState] = [:]
  var mcpRefreshingServers: Set<UUID> = []
  var codexBackgroundTerminals: [UUID: CodexBackgroundTerminal] = [:]
  var backgroundTerminalCleanup: [String: UUID] = [:]
  var subagentElicitationBusy: Set<String> = []
  var subagentElicitationErrors: [String: String] = [:]
  var subagentApprovalBusy: Set<String> = []
  var subagentStopBusy: [String: String] = [:]
  var subagentStopErrors: [String: String] = [:]
  var subagentApprovalErrors: [String: String] = [:]
  var subagentLiveStates: [String: SubagentLiveState] = [:] { didSet { synchronizeActivityPriority() } }
  @ObservationIgnored var subagentNotifiedRequests: Set<String> = []
  @ObservationIgnored var subagentSnapshotAssemblers: [String: CodexSubagentSnapshotAssembler] = [:]
  @ObservationIgnored var subagentSnapshotRevisions: [String: Int] = [:]
  @ObservationIgnored var backgroundTerminalCleanupRequests: Set<String> = []
  var mcpPendingApprovals: [UUID: MCPApprovalContext] = [:] { didSet { synchronizeActivityPriority() } }
  @ObservationIgnored var mcpApprovalContinuations: [UUID: CheckedContinuation<MCPApprovalDecision, Never>] = [:]
  var codexPendingQuestions: [UUID: CodexQuestionContext] = [:] { didSet { synchronizeActivityPriority() } }
  @ObservationIgnored var codexQuestionContinuations: [UUID: CheckedContinuation<[String: [String]]?, Never>] = [:]
  @ObservationIgnored var promptedSkillDependencies: [String: Set<String>] = [:]
  var codexPendingElicitations: [UUID: CodexElicitationContext] = [:] { didSet { synchronizeActivityPriority() } }
  @ObservationIgnored var codexElicitationContinuations: [UUID: CheckedContinuation<CodexElicitationDecision?, Never>] = [:]
  @ObservationIgnored var codexSteeringMessages: Set<UUID> = []
  @ObservationIgnored var mcpTaskGrants: Set<String> = []
  @ObservationIgnored var mcpConnections: [UUID: MCPConnection] = [:]
  @ObservationIgnored var mcpConnectionTokens: [UUID: UUID] = [:]
  @ObservationIgnored var mcpConnectionTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored var mcpClosingTasks: [UUID: Task<Void, Never>] = [:]
  var automationPreferences = AutomationPreferences()
  var automationsLoaded = false
  var automationsLoading = false
  var automationsError: String?
  var automationRunningIDs: Set<UUID> = []
  var automationCreateRequest: UUID?
  var automationListRequest: UUID?
  var sshHosts: [SSHHost] = []
  var sshHostsLoaded = false
  var sshHostsLoading = false
  var sshHostsError: String?
  var sshTestingHost: String?
  var computerUsePreferences = ComputerUsePreferences()
  var computerUseLoaded = false
  var computerUseLoading = false
  var computerUseError: String?
  var screenRecordingGranted = false
  var accessibilityGranted = false
  var computerUseLastChecked = Date()
  var notifications = CompletionNotificationCenter()
  var sleepPrevention = SleepPrevention()
  var generalSettingsError: String?
  @ObservationIgnored var appearanceHandler: ((AppearancePreferences) -> Void)?
  var browserSettingsError: String?
  @ObservationIgnored var additionalTaskWindowPanels = NSHashTable<TaskWindowPanelSessions>.weakObjects()
  @ObservationIgnored var taskWindowResources = NSHashTable<TaskWindowResources>.weakObjects()
  @ObservationIgnored var restoringPinnedContentTabIDs = Set<String>()
  @ObservationIgnored var pinnedBrowserActionGenerations: [String: UUID] = [:]
  @ObservationIgnored var additionalBrowserSessions = NSHashTable<BrowserSession>.weakObjects()
  var browserDownloadProgress: [UUID: Double] = [:]
  @ObservationIgnored var messageDownloadIDs = Set<UUID>()
  var archivedTaskDeletionError: String?
  let notices = WorkspaceNotices()
  var restoringArchivedTaskIDs: Set<String> = []
  var archiveDeletion: ArchiveDeletionRequest?
  var deletingArchive = false
  var shortcutResetRequested = false
  var resettingShortcuts = false
  var shortcutResetError: String?
  var memoryDeletion: MemoryDeletionRequest?
  var deletingMemories = false
  var memoryDeletionError: String?
  var appearanceThemeImport: AppearanceThemeImportSession?
  var hasSettingsConfirmation: Bool {
    archiveDeletion != nil || shortcutResetRequested || memoryDeletion != nil || archiveConfirmation() != nil
      || appearanceThemeImport != nil || pendingSettingsNavigation != nil
      || hookSettings.selectedSourceID != nil
  }
  var shuttingDown = false
  var conversationReveal: ConversationRevealRequest?
  @ObservationIgnored var completionTracker = CompletionTracker()
  var showingModelPicker = false
  var showingBranchPicker = false
  var branchChangeError: String?
  var worktreeSource: String?
  var worktreeError: String?
  var importingImages = false
  var importingFiles = false
  var previewFile: FileAttachment?
  var previewImage: ImagePreviewItem?
  var previewImages: [ImagePreviewItem] = []
  @ObservationIgnored private var modelTasks: [String: Task<Void, Never>] = [:]
  @ObservationIgnored private var compatibilityModelTask: Task<Void, Never>?
  var modelTask: Task<Void, Never>? {
    get {
      if let id = selectedTask.flatMap({ activeChatRun(taskID: $0.id)?.id }),
        let task = modelTasks[id]
      { return task }
      return modelTasks.values.first ?? compatibilityModelTask
    }
    set {
      compatibilityModelTask = newValue
      updateSleepPrevention()
    }
  }
  var hasLiveModelRequests: Bool { !modelTasks.isEmpty || compatibilityModelTask != nil }
  var liveModelRequestCount: Int { modelTasks.count + (compatibilityModelTask == nil ? 0 : 1) }
  var lastChatSave = Date.distantPast
  var canSend: Bool {
    destination == .workspace && !importingImages && !importingFiles && !managedTaskPreparing
      && ((draft.trimmingCharacters(in: .whitespacesAndNewlines) == ComposerCommand.status.token
            && selectedTask != nil)
        || (draft.trimmingCharacters(in: .whitespacesAndNewlines) == ComposerCommand.worktree.token
            && commandEnabled("worktree"))
        || (draft.trimmingCharacters(in: .whitespacesAndNewlines) == ComposerCommand.local.token
            && commandEnabled("local"))
        || (action == .chat ? canStartChat : canStart)
        || selectedActiveRun?.kind == "chat")
  }
  var focusComposer = UUID()
  var blurComposer = UUID()
  @ObservationIgnored var libraryLoaded = false
  @ObservationIgnored let libraryReader: WorkspaceLibraryReader
  @ObservationIgnored let modelConfigurationReader: ModelConfigurationReader
  @ObservationIgnored var modelConfigurationRevision = UUID()
  @ObservationIgnored var modelConfigurationReadRequest: UUID?
  var modelConfigurationLoading = false
  var modelConfigurationRecoveryPending = false
  var modelConfigurationReadError: String?
  var subagentDraftSaveErrors: [SubagentDraftScope: String] = [:]
  @ObservationIgnored var subagentDraftEpochs: [SubagentDraftScope: UUID] = [:]
  @ObservationIgnored var retiredSubagentDraftImages: [UUID: ImageAttachment] = [:]
  @ObservationIgnored var retiredSubagentDraftFiles: [UUID: FileAttachment] = [:]
  var libraryLoading = false
  var libraryReadError: String?
  @ObservationIgnored var scopeLoaded = false
  @ObservationIgnored private(set) var preparingProjectScope = false
  @ObservationIgnored private var preparedScopeRunUpdates: Set<String> = []
  @ObservationIgnored private var preparedScopeEventGap = false
  var project: URL? {
    didSet {
      if project != oldValue {
        terminalFocusRequest = nil
        if settingsSearchRequest?.result.field?.requiresProject == true { settingsSearchRequest = nil }
      }
    }
  }
  var inspection: ProjectInspection?
  var runs: [AgentRun] = [] { didSet { updateSleepPrevention(); synchronizeActivityPriority() } }
  var selection: String? {
    willSet {
      if selection != newValue {
        captureWorkspaceTabLayout()
        workspaceLayoutActiveOwner = nil
      }
    }
    didSet { if selection != oldValue { terminalFocusRequest = nil } }
  }
  var events: [AgentEvent] = []
  var container = ""
  var scheme = ""
  var configuration = "Debug"
  var worktreeSetupScript = ""
  var setupPlatformScripts = EnvironmentPlatformScripts()
  var worktreeCleanupScript = ""
  var cleanupPlatformScripts = EnvironmentPlatformScripts()
  var environmentActions: [EnvironmentAction] = []
  var environmentFiles: [LocalEnvironmentEntry] = []
  var environmentCatalog: [String: [LocalEnvironmentEntry]] = [:]
  var environmentCatalogErrors: [String: String] = [:]
  var environmentCatalogLoading = false
  var environmentCatalogRequest = UUID()
  @ObservationIgnored var environmentSettingsNavigationRevision = UUID()
  var environmentSettingsSession = EnvironmentSettingsSession()
  var environmentSettingsOpenProject = false
  var environmentSettingsOpenEditor = false
  var environmentFileName = "environment.toml"
  var environmentName = ""
  var environmentRevision: String?
  var environmentExists = false
  var environmentStatus = ""
  var environmentSaving = false
  var environmentLoadedState: LocalEnvironmentFormState?
  @ObservationIgnored var environmentReadRequest = UUID()
  var connected = false { didSet { updateSleepPrevention() } }
  var busy = false
  let worktreeForkPresentation = WorktreeForkPresentation()
  var activeWorktreeForkPreparation: WorktreeForkPreparation?
  var managedTaskPreparing = false
  var managedTaskPreparationMessage = "正在创建工作树…"
  @ObservationIgnored var managedArchiveCleanupTask: Task<Void, Never>?
  @ObservationIgnored var managedLimitCleanupTask: Task<Void, Never>?
  @ObservationIgnored var managedDeletionCleanupTask: Task<Void, Never>?
  @ObservationIgnored var pendingHandoffRecoveryTask: Task<Void, Never>?
  var recoveringHandoffTaskIDs: Set<String> = []
  var newTaskStartingBranches: [String: GitBranchChoice] = [:]
  var restoringLibrary = false
  var restorationReadError: String? {
    (!libraryLoaded ? libraryReadError : nil) ?? modelConfigurationReadError
  }
  var libraryRecoveryBlocksInteraction: Bool {
    restoringLibrary || modelConfigurationRecoveryPending || restorationReadError != nil
  }
  var error: String?
  var logText = ""
  var logName = "stdout.log"
  var config: JSONValue = .null
  var dataDirectory: URL?
  @ObservationIgnored let client: AgentClient
  @ObservationIgnored let codexTransport: CodexChatTransport
  @ObservationIgnored private(set) var session = UUID()
  @ObservationIgnored private var detailVersion = UUID()

  var selectedTask: WorkspaceTask? { library.task(containing: selection) }
  var conversationRuns: [AgentRun] {
    guard let task = selectedTask else { return [] }
    return taskWindowRuns(task.id)
  }
  var visibleTasks: [WorkspaceTask] {
    library.visible(project: project?.path ?? "", query: query, archived: showingArchived)
  }
  var draftKey: String {
    if let selectedTask { return selectedTask.id }
    let base = "new:\(project == nil ? "none" : currentDraftProjectKey)"
    return library.linkedNewTaskDraftIDs[currentDraftProjectKey]
      .map { "\(base):link:\($0.uuidString)" } ?? base
  }
  var draft: String {
    get { library.drafts[draftKey] ?? "" }
    set {
      library.drafts[draftKey] = newValue
      saveLibrary()
    }
  }
  var selectedRun: AgentRun? { runs.first { $0.id == selection } }
  var activeRun: AgentRun? { runs.first { $0.isActive } }
  var activeLocalRun: AgentRun? { runs.first { $0.isActive && $0.kind != "chat" } }
  var selectedActiveRun: AgentRun? {
    guard let task = selectedTask else { return nil }
    return activeRun(taskID: task.id)
  }
  var currentProjectKey: String { project?.path ?? "" }
  var currentDraftProjectKey: String { library.projectOwner(for: currentProjectKey) }
  var canStartChat: Bool { canStartChat(taskID: selectedTask?.id) }
  var canStart: Bool {
    project != nil && connected && !busy && !libraryRecoveryBlocksInteraction && !managedTaskPreparing
      && !handoffBlocksProject(currentProjectKey)
      && activeLocalRun == nil && !shuttingDown
      && (selectedTask.map { !$0.archived && !activityArchivingTaskIDs.contains($0.id) } ?? true)
  }
  var canBuild: Bool {
    canStart && !container.isEmpty
      && !scheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  var dataRoot: URL { root }
  private static var defaultDataRoot: URL {
    let args = CommandLine.arguments
    if let index = args.firstIndex(of: "--data-root"), args.indices.contains(index + 1) {
      return URL(fileURLWithPath: args[index + 1], isDirectory: true)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ShipiOS/Desktop", isDirectory: true)
  }
  var executable: URL {
    agentExecutable ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/shipios-agent")
  }

  func activeRun(taskID: String) -> AgentRun? {
    guard let task = library.tasks.first(where: { $0.id == taskID }) else { return nil }
    let available = Dictionary(
      (runs + library.localRuns).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return task.runIDs.reversed().compactMap { available[$0] }.first(where: \.isActive)
  }

  func activeChatRun(taskID: String) -> AgentRun? {
    activeRun(taskID: taskID).flatMap { $0.kind == "chat" ? $0 : nil }
  }

  func canStartChat(taskID: String?, continuingWatchInspectionRunID: String? = nil) -> Bool {
    guard !busy, !libraryRecoveryBlocksInteraction, !managedTaskPreparing, !shuttingDown else { return false }
    if let taskID {
      if let preparation = watchWorktreePreparationRun(taskID: taskID),
        preparation.id != continuingWatchInspectionRunID { return false }
      guard !activityArchivingTaskIDs.contains(taskID),
        library.tasks.contains(where: { $0.id == taskID && !$0.archived }) else { return false }
      guard !library.managedWorktrees.contains(where: {
        $0.containsTask(taskID) && $0.pendingForkSourceTaskID != nil
      }) else { return false }
    }
    let requestedProject = taskID.flatMap { id in
      library.tasks.first(where: { $0.id == id })?.project
    } ?? currentProjectKey
    guard !handoffBlocksProject(requestedProject) else { return false }
    return taskID.map { taskID in
      activeRun(taskID: taskID) == nil
    } ?? true
  }

  func handoffBlocksProject(_ path: String) -> Bool {
    guard !path.isEmpty else { return false }
    return library.managedWorktrees.contains { record in
      guard let snapshot = record.pendingHandoff?.snapshot else { return false }
      return snapshot.sourcePath == path || snapshot.targetPath == path
    }
  }

  func installModelTask(_ task: Task<Void, Never>, runID: String) {
    modelTasks[runID] = task
    updateSleepPrevention()
  }

  func removeModelTask(runID: String) {
    modelTasks[runID] = nil
    updateSleepPrevention()
  }

  func modelTask(runID: String) -> Task<Void, Never>? { modelTasks[runID] }

  init(dataRoot: URL? = nil, agentExecutable: URL? = nil,
    browserDataStore: WKWebsiteDataStore? = nil, libraryReader: WorkspaceLibraryReader? = nil,
    modelConfigurationReader: ModelConfigurationReader? = nil) {
    root = dataRoot ?? Self.defaultDataRoot
    self.libraryReader = libraryReader ?? WorkspaceLibraryReader(url: root.appendingPathComponent("workspace.json"))
    self.modelConfigurationReader = modelConfigurationReader
      ?? ModelConfigurationReader(url: root.appendingPathComponent("model.json"))
    hookSettings = HookSettingsState(root: root)
    voiceRecordingHistory = VoiceRecordingHistory(dataRoot: root)
    self.agentExecutable = agentExecutable
    self.browserDataStore = browserDataStore
    shortcuts = ShortcutPreferences(file: root.appendingPathComponent("shortcuts.json"))
    let agentClient = AgentClient()
    client = agentClient
    codexTransport = CodexChatTransport(dataRoot: root)
    bindGitReviewPolicy(to: workspace)
    codexTransport.onThreadStarted = { [weak self] taskID, threadID, workspace in
      self?.recordCodexThreadID(taskID: taskID, threadID: threadID, workspace: workspace)
    }
    codexTransport.onRuntimeCommandEvent = { [weak self] taskID, threadID, event in
      self?.recordCodexRuntimeCommand(taskID: taskID, threadID: threadID, event: event)
    }
    codexTransport.onThreadDisconnected = { [weak self] taskID in
      self?.disconnectBackgroundTerminals(taskID: taskID)
      self?.disconnectSubagents(taskID: taskID)
    }
    codexTransport.onSubagentEvent = { [weak self] taskID, threadID, event in
      self?.recordSubagentEvent(taskID: taskID, threadID: threadID, event: event)
    }
    codexTransport.onSubagentSubmission = { [weak self] record in
      guard let self else { throw AgentFailure(message: "工作区已关闭。") }
      try self.recordSubagentSubmission(record)
    }
    codexTransport.onSubagentSnapshot = { [weak self] taskID, threadID, event in
      self?.recordSubagentSnapshot(taskID: taskID, threadID: threadID, event: event)
    }
    codexTransport.onHookEvent = { [weak self] taskID, threadID, event in
      self?.recordCodexHook(taskID: taskID, threadID: threadID, event: event)
    }
    codexTransport.onBrowserRequest = { [weak self] taskID, token, request in
      Task { @MainActor [weak self] in
        await self?.handleCodexBrowserRequest(taskID: taskID, token: token, request: request)
      }
    }
    workspace.browser = BrowserSession(dataStore: browserDataStore)
    workspace.browser.selectsAdjacentTabOnClose = false
    workspace.browser.createChildTab = { [weak self] id, configuration in
      self?.newBrowserChild(from: id, configuration: configuration)
    }
    workspace.browser.onTabOpened = { [weak self] id in self?.workspaceBrowserDidOpen(id) }
    workspace.browser.onTabSelected = { [weak self] id in self?.workspaceBrowserDidSelect(id) }
    workspace.browser.onTabClosed = { [weak self] id, reason in self?.workspaceBrowserDidClose(id, reason: reason) }
    workspace.browser.onTabsReordered = { [weak self] ids in self?.workspaceBrowserDidReorder(ids) }
    workspace.browser.onTabMoved = { [weak self] id in
      guard let self, let tab = self.workspaceTabs.first(where: { $0.browserID == id }) else { return }
      self.recordWorkspaceTabMoved(tab)
    }
    workspace.browser.onEmpty = { [weak self] in
      guard let self else { return }
      let wasVisible = self.browserVisible
      if self.pane == "browser", self.workspacePrimaryContentTabs.isEmpty { self.showingInspector = false }
      if wasVisible, self.workspacePrimaryContentTabs.isEmpty { self.activateChatTab() }
    }
    workspace.browser.onVisit = { [weak self] url, title, newVisit in
      self?.recordBrowserVisit(url, title: title, newVisit: newVisit)
    }
    workspace.browser.onTabRenamed = { [weak self] id in self?.workspaceBrowserRenamed(id) }
    workspace.browser.chooseDownloadDestination = { [weak self] source, filename, completion in
      self?.chooseBrowserDownloadDestination(source: source, filename: filename, completion: completion)
        ?? completion(.cancel)
    }
    workspace.browser.onDownloadEvent = { [weak self] event in self?.handleBrowserDownload(event) }
    client.onEvent = { [weak self] event in
      guard let self else { return }
      if self.preparingProjectScope {
        self.preparedScopeRunUpdates.insert(event.runId)
        return
      }
      let token = self.session
      Task { await self.refresh(runID: event.runId, token: token) }
    }
    client.onGap = { [weak self] in
      guard let self else { return }
      if self.preparingProjectScope {
        self.preparedScopeEventGap = true
        return
      }
      let token = self.session
      Task { if self.session == token { await self.reload() } }
    }
    client.onDisconnect = { [weak self] message in
      self?.connected = false
      self?.error = message
    }
    connectShortcutSettingsStorage()
  }

  func restore() async {
    guard !scopeLoaded, project == nil, !restoringLibrary, !shuttingDown, !Task.isCancelled else { return }
    restoringLibrary = true
    defer { restoringLibrary = false }
    guard await loadLibrary() else { return }
    guard await loadModelConfiguration() else { return }
    discardRestoredSideChats()
    await cleanupPendingManagedWorktreeDeletions()
    await loadPersonalization()
    await loadMemories()
    await loadProfile()
    await loadPets()
    await loadPlugins()
    await loadMCPServers()
    await loadAutomations()
    await loadComputerUsePreferences()
    restoreInterruptedChats()
    // visit() keeps this data root's most recently opened project first.
    if let path = library.lastWorkspace ?? library.projects.first, !path.isEmpty,
      FileManager.default.fileExists(atPath: path)
    {
      await open(URL(fileURLWithPath: path), usePrimary: library.lastWorkspace == nil)
    } else {
      await openProjectless()
    }
    scheduleManagedLimitCleanup()
    schedulePendingHandoffRecovery()
  }

  /// Switches to a scope with no filesystem root and no local Agent connection.
  func openProjectless(stillValid: () -> Bool = { true }) async {
    guard activeLocalRun == nil, !busy, await loadLibrary(), stillValid() else { return }
    worktreeForkPresentation.dismiss()
    captureWorkspaceTabLayout()
    rememberProjectSelection()
    saveProfile()
    busy = true
    defer { busy = false }
    connected = false
    session = UUID()
    environmentSaving = false
    let token = session
    await client.stop()
    guard session == token, stillValid() else { return }
    workspaceLayoutActiveOwner = nil
    workspaceContentLayoutMode = nil
    project = nil
    workspace.setProject(nil)
    destination = .workspace
    dataDirectory = nil
    inspection = nil
    config = .null
    container = ""
    scheme = ""
    configuration = "Debug"
    worktreeSetupScript = ""
    setupPlatformScripts = .init()
    worktreeCleanupScript = ""
    cleanupPlatformScripts = .init()
    environmentActions = []
    environmentFiles = []
    environmentFileName = "environment.toml"
    environmentName = ""
    environmentRevision = nil
    environmentExists = false
    environmentStatus = ""
    environmentLoadedState = nil
    action = .chat
    events = []
    logText = ""
    error = nil
    showingTerminal = false
    showingInspector = false
    showingFind = false
    showingModelPicker = false
    presentedOverlay = nil
    runs = library.localRuns.filter { $0.project.isEmpty }
    completionTracker.seed(runs)
    selection = library.rememberedSelection(project: "")
    chatMode = selectedTask.flatMap { library.goalSessions[$0.id] }?.status == .active
      ? .goal : .standard
    showingArchived = false
    query = ""
    library.lastWorkspace = ""
    scopeLoaded = true
    restoreWorkspaceTabLayout()
    saveLibrary()
  }

  @discardableResult func openTaskScope(_ key: String, loadsDetails: Bool = true,
    preservingWorktreePreparation: WorktreeForkPreparation? = nil, stillValid: () -> Bool = { true }) async -> Bool {
    guard stillValid() else { return false }
    if let preparation = worktreeForkPresentation.preparation, preparation !== preservingWorktreePreparation {
      worktreeForkPresentation.dismiss()
    }
    if key == currentProjectKey && (key.isEmpty || connected) { return true }
    if let managed = library.managedWorktrees.first(where: { $0.path == key }),
      managed.archivedPruned == true || !FileManager.default.fileExists(atPath: managed.path) {
      guard await restoreManagedArchiveIfNeeded(managed.taskID) else {
        notices.show(id: "managed-restore-" + managed.taskID,
          title: archivedTaskDeletionError ?? "无法恢复工作树", level: .error)
        return false
      }
    }
    guard stillValid() else { return false }
    if key.isEmpty { await openProjectless(stillValid: stillValid) }
    else {
      await open(URL(fileURLWithPath: key), usePrimary: false, loadsDetails: loadsDetails,
        preservingWorktreePreparation: preservingWorktreePreparation, stillValid: stillValid)
    }
    return stillValid() && currentProjectKey == key && (key.isEmpty || connected)
  }

  func newChat() async {
    if let project { await newTask(in: project.path) }
    else { await newProjectlessTask() }
  }

  func newProjectlessTask() async {
    guard !busy, project == nil || activeLocalRun == nil else { return }
    recordNavigation()
    if project != nil { await openProjectless() }
    guard project == nil else { return }
    action = .chat
    newTask(recordHistory: false)
  }

  func chooseProject(createNewTask: Bool = false) {
    guard activeLocalRun == nil, !busy, !restoringLibrary else { return }
    let panel = NSOpenPanel()
    panel.title = "选择项目所在文件夹"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    guard let window = NSApp.keyWindow else { return }
    panel.beginSheetModal(for: window) { [weak self] response in
      if response == .OK, let url = panel.url {
        Task { @MainActor in
          if createNewTask {
            await self?.newTask(in: url.resolvingSymlinksInPath().standardizedFileURL.path)
          }
          else { await self?.open(url) }
        }
      }
    }
  }

  func openDemo() async {
    do {
      let destination = dataRoot.appendingPathComponent("Demo/HelloShipiOS", isDirectory: true)
      if !FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.createDirectory(
          at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(
          at: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/HelloShipiOS"),
          to: destination)
      }
      await open(destination)
      if container == "HelloShipiOS.xcodeproj" { scheme = "HelloShipiOS" }
    } catch { self.error = error.localizedDescription }
  }

  func open(_ url: URL, usePrimary: Bool = true, loadsDetails: Bool = true,
    preservingWorktreePreparation: WorktreeForkPreparation? = nil, stillValid: () -> Bool = { true }) async {
    guard activeLocalRun == nil || !connected, !busy else { return }
    if let preparation = worktreeForkPresentation.preparation, preparation !== preservingWorktreePreparation {
      worktreeForkPresentation.dismiss()
    }
    guard await loadLibrary(), stillValid() else { return }
    let requested = url.resolvingSymlinksInPath().standardizedFileURL
    let canonical = usePrimary
      ? URL(fileURLWithPath: library.primaryFolder(for: requested.path), isDirectory: true)
        .resolvingSymlinksInPath().standardizedFileURL : requested
    if project == canonical && connected {
      returnToWorkspace()
      return
    }
    captureWorkspaceTabLayout()
    rememberProjectSelection()
    saveProfile()
    destination = .workspace
    busy = true
    preparingProjectScope = true
    connected = false
    error = nil
    session = UUID()
    environmentSaving = false
    let token = session
    await client.stop()
    defer {
      busy = false; preparingProjectScope = false
      preparedScopeRunUpdates.removeAll(); preparedScopeEventGap = false
    }
    do {
      let digest = SHA256.hash(data: Data(canonical.path.utf8)).map { String(format: "%02x", $0) }
        .joined()
      let directory = dataRoot.appendingPathComponent("Projects/\(digest)", isDirectory: true)
      try client.start(executable: executable, project: canonical, dataDirectory: directory)
      let hello = try await client.request("initialize", ["protocolVersion": .number(1)])
      guard hello["protocolVersion"].int == 1 else {
        throw AgentFailure(message: "不支持的 Agent 协议版本")
      }
      let preparedInspection = try await client.request("project.inspect").decode(ProjectInspection.self)
      let preparedConfig = try await client.request("config.get")
      guard session == token else { return }
      guard stillValid() else { await client.stop(); return }
      let preparedEnvironment = await prepareProjectScopeEnvironment(canonical)
      guard session == token else { return }
      guard stillValid() else { await client.stop(); return }
      // Earlier events are covered by this final snapshot. Keep notifications
      // that arrive while it is being read, since they may be newer than it.
      preparedScopeRunUpdates.removeAll(); preparedScopeEventGap = false
      let preparedRuns =
        try await client.request("run.list").decode([AgentRun].self)
        + library.localRuns.filter { $0.project == canonical.path }
      guard session == token else { return }
      guard stillValid() else { await client.stop(); return }
      // Failed initialization must not replace the task, draft, files or panels.
      // The previous local Agent has stopped; connection state remains truthful.
      workspaceLayoutActiveOwner = nil
      workspaceContentLayoutMode = nil
      project = canonical
      dataDirectory = directory
      runs = preparedRuns
      selection = library.rememberedSelection(project: canonical.path)
      chatMode = selectedTask.flatMap { library.goalSessions[$0.id] }?.status == .active
        ? .goal : .standard
      workspace.setProject(canonical, additionalFolders: additionalWorkspaceFolders(for: canonical))
      events = []
      logText = ""
      inspection = preparedInspection
      config = preparedConfig
      container = ""
      scheme = ""
      configuration = "Debug"
      completionTracker.seed(runs)
      connected = true
      preparingProjectScope = false
      scopeLoaded = true
      container = inspection?.containers.first ?? ""
      scheme = UserDefaults.standard.string(forKey: "scheme.\(digest)") ?? ""
      if let profile = library.profiles[project!.path] {
        if inspection?.containers.contains(profile.container) == true {
          container = profile.container
        }
        scheme = profile.scheme
        configuration = profile.configuration

      }
      applyProjectScopeEnvironment(preparedEnvironment)
      action = .chat
      library.lastWorkspace = project!.path
      library.visit(project!.path)
      library.reconcile(runs, project: project!.path)
      saveLibrary()
      showingArchived = false
      query = ""
      selection = library.rememberedSelection(project: project!.path)
      chatMode = selectedTask.flatMap { library.goalSessions[$0.id] }?.status == .active
        ? .goal : .standard
      restoreWorkspaceTabLayout()
      replayPreparedScopeUpdates(token: token)
      if loadsDetails { await loadDetails() }
    } catch {
      self.error = error.localizedDescription
      await client.stop()
    }
  }

  private func replayPreparedScopeUpdates(token: UUID) {
    let runIDs = preparedScopeRunUpdates, gap = preparedScopeEventGap
    preparedScopeRunUpdates.removeAll(); preparedScopeEventGap = false
    guard gap || !runIDs.isEmpty else { return }
    Task {
      guard session == token, connected, !preparingProjectScope else { return }
      if gap { await reload() }
      else {
        for id in runIDs { await refresh(runID: id, token: token) }
      }
    }
  }

  func start(_ kind: String, note: String = "", consumeDraft: Bool = false,
    pullRequestChecks: PullRequestCheckDraft? = nil) async {
    if selectedTask == nil, !(await applyPrimaryToNewTask()) { return }
    if kind == "chat" {
      await startChat(
        note, consumeDraft: consumeDraft, images: consumeDraft ? draftImages : [],
        files: consumeDraft ? draftFiles : [], mode: chatMode, pullRequestChecks: pullRequestChecks)
      return
    }
    var request: [String: JSONValue] = ["kind": .string(kind)]
    if kind == "build" {
      guard canBuild else { return }
      request["container"] = .string(container)
      request["scheme"] = .string(scheme.trimmingCharacters(in: .whitespacesAndNewlines))
      request["configuration"] = .string(configuration)
    }
    await submit(request, note: note, consumeDraft: consumeDraft)
  }

  private func submit(
    _ request: [String: JSONValue], note: String = "", consumeDraft: Bool = false
  ) async {
    guard canStart else { return }
    let taskID = selectedTask?.id
    let submittedDraftKey = draftKey
    let submittedTerminal = taskID == nil ? terminalScope : nil
    busy = true
    error = nil
    defer { busy = false }
    do {
      let branch = await branchForTaskHistory()
      guard !shuttingDown, !Task.isCancelled else { return }
      let run = try await client.request("run.start", request).decode(AgentRun.self)
      library.attach(run, to: taskID, note: note)
      library.runBranches[run.id] = branch
      adoptDraftTerminal(submittedTerminal, run: run)
      completionTracker.begin(run.id)
      if consumeDraft { library.drafts[submittedDraftKey] = nil }
      showingArchived = false
      selection = run.id
      saveProfile()
      saveLibrary()
      if let directory = dataDirectory {
        UserDefaults.standard.set(scheme, forKey: "scheme.\(directory.lastPathComponent)")
      }
      await refresh(runID: run.id, token: session)
    } catch { self.error = error.localizedDescription }
  }

  func rerun() async {
    guard let run = selectedRun, !run.isActive, case .object(let request) = run.request else {
      return
    }
    if run.kind == "chat" {
      if request["conversation_kind"]?.text == "review" {
        do {
          let originalID = library.forkRunOrigins[run.id] ?? run.id
          let snapshot = try ReviewSnapshotStorage.load(runID: originalID, root: dataRoot)
          guard request["review_scope"]?.text == snapshot.scope.metadataValue,
            request["review_selection"]?.text == snapshot.scope.selection,
            let delivery = request["review_delivery"]?.text.flatMap(ReviewDelivery.init(rawValue:)),
            let owner = library.task(containing: run.id) else {
            throw AgentFailure(message: "原审查范围或所属任务已失效，无法重新运行。")
          }
          await startChat(snapshot.requestTitle, taskID: owner.id,
            review: ModelCodeReviewContext(snapshot: snapshot, delivery: delivery))
        } catch { self.error = error.localizedDescription }
        return
      }
      await startChat(
        library.notes[run.id] ?? "", images: library.runImages[run.id] ?? [],
        files: library.runFiles[run.id] ?? [],
        mode: ChatMode(rawValue: request["mode"]?.text ?? "") ?? .standard)
      return
    }
    await submit(request, note: library.notes[run.id] ?? "")
  }

  func reload() async {
    if project == nil {
      runs = library.localRuns.filter { $0.project.isEmpty }
      observeCompletions(runs)
      return
    }
    guard connected, !preparingProjectScope else { return }
    let token = session
    do {
      let fetched = try await client.request("run.list").decode([AgentRun].self)
      guard session == token, connected, !preparingProjectScope else { return }
      runs = fetched + library.localRuns.filter { $0.project == project?.path }
      library.reconcile(runs, project: project?.path ?? "")
      observeCompletions(runs)
      saveLibrary()
      await loadDetails()
    } catch { if session == token, !preparingProjectScope { self.error = error.localizedDescription } }
  }

  private func refresh(runID: String, token: UUID) async {
    guard session == token, connected, !preparingProjectScope else { return }
    do {
      let run = try await client.request("run.get", ["runId": .string(runID)]).decode(AgentRun.self)
      guard session == token, connected, !preparingProjectScope else { return }
      if let index = runs.firstIndex(where: { $0.id == run.id }) {
        // Late responses must never turn a terminal task back into an active task.
        if runs[index].updatedAt <= run.updatedAt && (runs[index].isActive || !run.isActive) {
          runs[index] = run
        }
      } else {
        runs.insert(run, at: 0)
      }
      if let latest = runs.first(where: { $0.id == runID }) { observeCompletions([latest]) }
      if selection == runID { await loadDetails() }
    } catch { if session == token && connected { self.error = error.localizedDescription } }
  }

  func loadDetails() async {
    let version = UUID()
    detailVersion = version
    events = []
    logText = ""
    guard connected, let run = selectedRun, run.kind != "chat" else { return }
    let requestedSelection = selection, requestedSession = session
    let isCurrent = {
      self.detailVersion == version && self.session == requestedSession && self.selection == requestedSelection
    }
    do {
      let response = try await client.request("run.events", ["runId": .string(library.forkRunOrigins[run.id] ?? run.id)])
      let fetched = try response["events"].decode([AgentEvent].self)
      guard isCurrent() else { return }
      events = fetched
      if run.result?["artifactDirectory"].text != nil {
        let log = try await client.request(
          "artifact.get", ["runId": .string(library.forkRunOrigins[run.id] ?? run.id), "name": .string(logName)])
        guard isCurrent() else { return }
        logText =
          (log["text"].text ?? "")
          + (log["truncated"].boolean == true ? "\n…显示前 256 KiB；完整日志位于产物文件夹。" : "")
      }
    } catch { if isCurrent() { logText = error.localizedDescription } }
  }

  func exportReport() async {
    guard let run = selectedRun, !run.isActive else { return }
    do {
      let report =
        run.kind == "chat"
        ? try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(run))
        : try await client.request("run.report", ["runId": .string(library.forkRunOrigins[run.id] ?? run.id)])
      let panel = NSSavePanel()
      panel.allowedContentTypes = [.json]
      panel.nameFieldStringValue = "shipios-\(run.id).json"
      guard let window = NSApp.keyWindow else { return }
      let response = await withCheckedContinuation { continuation in
        panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
      }
      if response == .OK, let url = panel.url {
        try Data(report.pretty.utf8).write(to: url, options: .atomic)
      }
    } catch { self.error = error.localizedDescription }
  }

  func revealArtifacts() {
    guard let path = selectedRun?.result?["artifactDirectory"].text else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
  }

  func newTask(recordHistory: Bool = true) {
    if let project, let managed = library.managedWorktrees.first(where: { $0.path == project.path }) {
      Task { await newTask(in: managed.source) }
      return
    }
    if let project, library.primaryFolder(for: project.path) != project.path {
      Task { await newTask(in: library.projectOwner(for: project.path)) }
      return
    }
    _ = applyWorkspaceDraftSelection(
      WorkspaceDraftIdentity(project: project == nil ? nil : currentDraftProjectKey), recordHistory: recordHistory)
  }

  func selectTask(_ task: WorkspaceTask) {
    if let preparation = activeWorktreeForkPreparation, preparation.taskID == task.id {
      destination = .workspace
      worktreeForkPresentation.present(preparation)
      return
    }
    if library.managedWorktrees.contains(where: { $0.containsTask(task.id) && $0.pendingForkSourceTaskID != nil }) {
      Task { _ = await resumeWorktreeFork(task.id) }
      return
    }
    guard canSelectTask(task) else { return }
    worktreeForkPresentation.dismiss()
    guard currentProjectKey == task.project else {
      Task { _ = await selectTaskAwaitingScope(task) }
      return
    }
    // Seed the restored current task too when migrating a library without visits.
    if let previous = selectedTask, library.recordTaskVisit(previous.id) { saveLibrary() }
    recordNavigation()
    applyTaskSelection(task)
  }

  /// Window search must reveal the main window after a cross-project scope has
  /// finished loading and its restored content windows have been scheduled.
  @discardableResult func selectTaskAwaitingScope(_ task: WorkspaceTask) async -> Bool {
    if let preparation = activeWorktreeForkPreparation, preparation.taskID == task.id {
      destination = .workspace
      worktreeForkPresentation.present(preparation)
      let result = await preparation.value()
      return !Task.isCancelled && result != nil && destination == .workspace && selectedTask?.id == task.id
    }
    guard let current = library.tasks.first(where: { $0.id == task.id }), canSelectTask(current) else { return false }
    if library.managedWorktrees.contains(where: {
      $0.containsTask(current.id) && $0.pendingForkSourceTaskID != nil
    }) {
      let result = await resumeWorktreeFork(current.id)
      return !Task.isCancelled && result != nil && destination == .workspace && selectedTask?.id == current.id
    }
    worktreeForkPresentation.dismiss()
    if currentProjectKey == current.project {
      selectTask(current)
      return true
    }
    if let previous = selectedTask, library.recordTaskVisit(previous.id) { saveLibrary() }
    let origin = currentTaskLocation
    guard await openTaskScope(current.project), !shuttingDown,
      let refreshed = library.tasks.first(where: { $0.id == task.id }), canSelectTask(refreshed) else { return false }
    recordNavigation(origin)
    applyTaskSelection(refreshed)
    return true
  }

  func applyTaskSelection(_ task: WorkspaceTask) {
    workspace.browser.cancelRename()
    captureWorkspaceTabLayout()
    workspaceLayoutActiveOwner = nil
    destination = .workspace
    pendingGoal = nil
    selection = task.selectionID
    workspaceContentLayoutMode = nil
    activeWorkspaceTabID = nil
    activeRightWorkspaceTabID = nil
    activeBottomWorkspaceTabID = nil
    focusedWorkspaceTabID = nil
    showingArchived = task.archived
    chatMode = library.goalSessions[task.id]?.status == .active ? .goal : .standard
    let sidebarProject = library.sidebarProject(for: task)
    library.collapsedProjects.remove(sidebarProject)
    for section in [
      library.sidebarSection(for: .task(task.id)),
      library.sidebarSection(for: .project(sidebarProject)),
    ] {
      if let index = library.sidebar.groups.firstIndex(where: { $0.id == section }) {
        library.sidebar.groups[index].collapsed = false
      }
    }
    library.unreadTasks.remove(task.id)
    library.recordTaskVisit(task.id)
    restoreWorkspaceTabLayout()
    rememberProjectSelection()
    saveLibrary()
    focusComposer = UUID()
    scheduleManagedLimitCleanup()
  }

  func sendDraft(followUpOverride: FollowUpBehavior? = nil) async {
    guard destination == .workspace, !importingImages && !importingFiles else { return }
    do {
      if handleComposerCommand() { return }
      let (chosen, originalNote) = try LocalAction.parse(draft, fallback: action)
      if chosen != .chat || draft.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/chat") {
        if chatMode == .goal { leaveGoalMode() }
        chatMode = .standard
      }
      let commentKey = draftKey
      let comments = reviewComments
      let pageComments = browserComments
      let checkDraft = pullRequestCheckDraft
      let images = draftImages
      let files = draftFiles
      guard (images.isEmpty && files.isEmpty) || chosen == .chat else {
        error = "附件用于模型会话，请切换到模型会话或先移除附件。"
        return
      }
      guard comments.isEmpty && pageComments.isEmpty && checkDraft == nil || chosen == .chat else {
        error = "请切换到模型会话发送评论，或先移除评论。"
        return
      }
      let note = try promptWithBrowserComments(
        promptWithReviewComments(originalNote, comments: comments), comments: pageComments)
      _ = try promptWithPullRequestChecks(note, checks: checkDraft, taskID: selectedTask?.id)
      let commentIDs = Set(comments.map(\.id))
      let pageCommentIDs = Set(pageComments.map(\.id))
      if selectedActiveRun?.kind == "chat", chosen == .chat, !note.isEmpty || !images.isEmpty || !files.isEmpty || checkDraft != nil {
        if selectedActiveRun?.request["api_protocol"].text == ModelAPIProtocol.codexResponses.rawValue,
          chatMode != .standard {
          error = "Codex Responses 的运行中追加消息当前仅支持普通模式。"
          return
        }
        guard let task = selectedTask else {
          error = "请在运行中的任务内追加消息。"
          return
        }
        let behavior = followUpOverride ?? followUpBehavior
        let message = QueuedMessage(
          taskID: task.id, text: note, images: images, files: files, mode: chatMode, pullRequestChecks: checkDraft)
        var candidate = library
        if behavior == .steer,
          let first = candidate.queuedMessages.firstIndex(where: { $0.taskID == task.id })
        {
          candidate.queuedMessages.insert(message, at: first)
        } else {
          candidate.queuedMessages.append(message)
        }
        candidate.reviewComments[commentKey]?.removeAll { commentIDs.contains($0.id) }
        candidate.browserComments[commentKey]?.removeAll { pageCommentIDs.contains($0.id) }
        if candidate.pullRequestCheckDrafts[commentKey] == checkDraft { candidate.pullRequestCheckDrafts[commentKey] = nil }
        candidate.drafts[commentKey] = ""
        candidate.draftImages[commentKey] = nil
        candidate.draftFiles[commentKey] = nil
        try commitLibrary(candidate)
        chatMode = library.goalSessions[task.id]?.status == .active ? .goal : .standard
        if behavior == .steer { await steerActiveChat(with: message) }
        return
      }
      action = chosen
      if selectedTask == nil,
        library.managedWorktrees.contains(where: { $0.path == currentProjectKey }) {
        error = "此工作树仅属于原任务。请返回来源项目创建新任务。"
        return
      }
      guard chosen == .chat || project != nil else {
        error = "环境诊断和构建需要项目，请先打开项目文件夹。"
        return
      }
      guard chosen != .build || canBuild else {
        error = "请先选择工程并填写 Scheme，再构建项目。"
        return
      }
      if chosen == .chat, selectedTask == nil, newTaskExecution == .worktree {
        guard comments.isEmpty, pageComments.isEmpty else {
          error = "请先移除来自本地检出的审查或网页评论，再创建工作树任务。"
          return
        }
        guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || !images.isEmpty || !files.isEmpty else { return }
        if await prepareManagedWorktreeTask() { await sendDraft() }
        return
      }
      let chatCount = library.chatRuns.count
      await start(chosen.rawValue, note: note, consumeDraft: true, pullRequestChecks: checkDraft)
      if chosen == .chat, library.chatRuns.count > chatCount {
        moveWorkspaceTabs(from: commentKey, to: draftKey)
        chatMode = selectedTask.flatMap { library.goalSessions[$0.id] }?.status == .active
          ? .goal : .standard
        library.reviewComments[commentKey]?.removeAll { commentIDs.contains($0.id) }
        library.browserComments[commentKey]?.removeAll { pageCommentIDs.contains($0.id) }
        saveLibrary()
      }
    } catch { self.error = error.localizedDescription }
  }

  func updateTask(_ id: String, title: String? = nil, pin: Bool? = nil, archive: Bool? = nil) {
    guard let index = library.tasks.firstIndex(where: { $0.id == id }) else { return }
    if archive != nil,
      managedTaskPreparing || library.managedWorktrees.contains(where: {
        $0.containsTask(id) && $0.pendingHandoff != nil
      }) { return }
    if archive == false,
      let managed = library.managedWorktrees.first(where: { $0.containsTask(id) }),
      managed.archivedPruned == true || !FileManager.default.fileExists(atPath: managed.path) {
      Task { await restoreArchivedTaskWithFeedback(id) }
      return
    }
    if let archive, archive, activeRun(taskID: id) != nil {
      return
    }
    if let title {
      let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !cleaned.isEmpty else { return }
      library.tasks[index].title = String(cleaned.prefix(120))
      library.tasks[index].updatedAt = Date()
    }
    if let pin {
      library.moveSidebarItem(
        .task(id),
        to: pin ? SidebarLayout.pinned : SidebarLayout.project(library.sidebarProject(for: library.tasks[index])))
    }
    if let archive {
      if archive && !library.tasks[index].archived {
        library.tasks[index].archivedAt = Date()
      } else if !archive {
        library.tasks[index].archivedAt = nil
      }
      library.tasks[index].archived = archive
      if archive && selectedTask?.id == id { newTask() }
    }
    let saved = saveLibrary()
    if saved, archive == true,
      library.managedWorktrees.contains(where: { $0.containsTask(id) }) {
      scheduleManagedArchiveCleanup(id)
    }
  }

  func showDetails(_ tab: String, run: AgentRun? = nil) {
    if let run { selection = run.id }
    inspectorTab = tab
    pane = "execution"
    showingInspector = true
  }

  func saveProfile() {
    guard libraryLoaded, let project else { return }
    library.profiles[project.path] = BuildProfile(
      container: container, scheme: scheme, configuration: configuration,
      worktreeSetupScript: worktreeSetupScript, setupPlatformScripts: setupPlatformScripts,
      worktreeCleanupScript: worktreeCleanupScript, cleanupPlatformScripts: cleanupPlatformScripts,
      actions: environmentActions, environmentFileName: environmentFileName)
    saveLibrary()
  }

  private func loadLibrary() async -> Bool {
    if libraryLoaded { return true }
    guard !libraryLoading else { return false }
    let previousReadError = libraryReadError
    libraryReadError = nil
    libraryLoading = true
    defer { libraryLoading = false }
    do {
      busy = true
      defer { busy = false }
      let restored = try await libraryReader.load()
      try Task.checkCancellation()
      if let snapshot = restored.shortcutPreferences { try shortcuts.restore(snapshot) }
      library = restored
      if library.appearance == nil {
        var appearance = AppearancePreferences()
        appearance.theme = UserDefaults.standard.string(forKey: "shipios.appearance") ?? "system"
        library.appearance = appearance.normalized()
      }
      libraryLoaded = true
      workspace.gitReviewLastTurnOnly = library.gitPreferences.disableGitBasedReview
      bindFileEditorRecovery(to: workspace)
      if error == previousReadError { error = nil }
      return true
    } catch {
      let message = "无法读取工作区记录：\(error.localizedDescription)"
      libraryReadError = message
      self.error = message
      return false
    }
  }

  func commitLibrary(_ candidate: WorkspaceLibrary, updatingSubagentDraft scope: SubagentDraftScope? = nil) throws {
    guard !modelConfigurationRecoveryPending, modelConfigurationReadError == nil else {
      throw AgentFailure(message: "模型配置尚未恢复，任务记录未被更改。请重试恢复。")
    }
    var candidate = candidate
    let updatedDraft = scope.flatMap { scope in candidate.subagentDrafts.first { $0.scope == scope } }
    // Other operations may have captured a library snapshot before an await.
    // Preserve current child input unless this commit explicitly edits that scope.
    candidate.subagentDrafts = library.subagentDrafts.filter { draft in
      draft.scope != scope && candidate.tasks.contains {
        $0.id == draft.scope.taskID && $0.codexThreadID == draft.scope.rootThreadID
      }
    }
    if let updatedDraft, candidate.tasks.contains(where: {
      $0.id == updatedDraft.scope.taskID && $0.codexThreadID == updatedDraft.scope.rootThreadID
    }) { candidate.subagentDrafts.append(updatedDraft) }
    if libraryLoaded { try candidate.save(to: dataRoot.appendingPathComponent("workspace.json")) }
    let retainedFiles = candidate.fileReferences
    let removedFiles = library.fileReferences.values.filter { retainedFiles[$0.id] == nil }
    let retained = candidate.imageReferences
    let removed = library.imageReferences.values.filter { retained[$0.id] == nil }
    library = candidate
    if libraryLoaded {
      for file in removedFiles {
        try? FileManager.default.removeItem(at: FileAttachmentStorage.url(file, root: dataRoot))
      }
      for image in removed {
        try? FileManager.default.removeItem(at: ImageAttachmentStorage.url(image, root: dataRoot))
      }
      finishSubagentDraftSave()
    }
  }

  @discardableResult func saveLibrary() -> Bool {
    guard libraryLoaded, !modelConfigurationRecoveryPending, modelConfigurationReadError == nil else { return false }
    captureWorkspaceTabLayout()
    autoreleasepool { taskWindowResources.allObjects.forEach { $0.captureLayouts() } }
    do {
      try library.save(to: dataRoot.appendingPathComponent("workspace.json"))
      finishSubagentDraftSave()
      return true
    } catch {
      self.error = "无法保存工作区记录：\(error.localizedDescription)"
      return false
    }
  }

  @discardableResult func shutdown(beforeTeardown: (() -> Void)? = nil) async -> Bool {
    await pendingHandoffRecoveryTask?.value
    await managedArchiveCleanupTask?.value
    await managedLimitCleanupTask?.value
    await managedDeletionCleanupTask?.value
    captureWorkspaceTabLayout()
    let editors = [workspace] + Array(fileTabWorkspaces.values)
      + taskWindowResources.allObjects.flatMap(\.fileRecoveryWorkspaces)
    guard captureFileEditorRecovery(from: editors, forceSave: true) else { return false }
    shuttingDown = true
    let forkWorker = activeWorktreeForkPreparation?.operation
    activeWorktreeForkPreparation?.cancel()
    worktreeForkPresentation.dismiss()
    _ = await forkWorker?.value
    beforeTeardown?()
    dictation.stop()
    realtimeVoice.stop()
    modelConfigurationReader.cancelPending()
    appshotIntroRequest = nil
    pendingAppshot = nil
    appshotHandoffAnimator.cancel()
    appshotHandoff = nil
    await shutdownMCPConnections()
    for id in Array(codexPendingQuestions.keys) { cancelCodexQuestion(id) }
    for id in Array(codexPendingElicitations.keys) { cancelCodexElicitation(id) }
    sleepPrevention.stop()
    for task in modelTasks.values { task.cancel() }
    compatibilityModelTask?.cancel()
    workspace.cancelCommitMessageGeneration()
    workspace.terminals.shutdown()
    taskWindowResources.allObjects.forEach { _ = $0.shutdown(force: true) }
    additionalTaskWindowPanels.allObjects.forEach { $0.shutdown() }
    additionalBrowserSessions.allObjects.forEach { $0.shutdown() }
    workspace.browser.shutdown()
    rememberProjectSelection()
    saveProfile()
    saveLibrary()
    connected = false
    session = UUID()
    environmentSaving = false
    await codexTransport.shutdown()
    // SessionEnd notifications can update historical runs during Agent teardown.
    saveLibrary()
    await environmentSettingsSession.close()
    await client.stop()
    return true
  }
}
