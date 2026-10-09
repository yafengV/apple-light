import Foundation
import Observation

struct LocalEnvironmentEntry: Decodable, Identifiable {
  let id: String
  let fileName: String
  let name: String?
  let error: String?
  let inherited: Bool
  let sourceFolder: String
  var title: String {
    let label = name.map { "\($0) · \(fileName)" } ?? fileName
    return inherited ? "\(label) — 来自 \(sourceFolder)" : label
  }
}

@MainActor @Observable
final class EnvironmentSettingsSession {
  var projectPath: String?
  var projectTitle = ""
  var files: [LocalEnvironmentEntry] = []
  var fileName = "environment.toml"
  var name = ""
  var setupScript = ""
  var setupPlatforms = EnvironmentPlatformScripts()
  var cleanupScript = ""
  var cleanupPlatforms = EnvironmentPlatformScripts()
  var actions: [EnvironmentAction] = []
  var revision: String?
  var exists = false
  var status = ""
  var connected = false
  var loading = false
  var saving = false
  var saveConflict = false
  var readError = false
  var parseError = false
  var loadedState: LocalEnvironmentFormState?
  @ObservationIgnored private var client: AgentClient?
  @ObservationIgnored private var temporary: URL?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var readRequest = UUID()

  var formState: LocalEnvironmentFormState {
    LocalEnvironmentFormState(name: name, setup: setupScript, setupPlatforms: setupPlatforms,
      cleanup: cleanupScript, cleanupPlatforms: cleanupPlatforms, actions: actions)
  }
  var hasUnsavedChanges: Bool { loadedState.map { $0 != formState } ?? false }
  var hasValidName: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  var hasValidActions: Bool { actions.allSatisfy(\.isRunnable) }
  var canSave: Bool {
    connected && !saving && !saveConflict && !readError && hasValidName && hasValidActions
      && (!exists || parseError || hasUnsavedChanges)
  }

  func open(_ path: String, title: String, executable: URL) async {
    let token = UUID()
    generation = token
    readRequest = UUID()
    saving = false
    loading = true
    await stopClient()
    guard generation == token else { return }
    projectPath = path
    projectTitle = title
    files = []
    fileName = "environment.toml"
    clearForm()
    status = ""
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("shipios-environment-editor-\(UUID())", isDirectory: true)
    let next = AgentClient()
    do {
      try next.start(executable: executable, project: URL(fileURLWithPath: path),
        dataDirectory: directory)
      _ = try await next.request("initialize", ["protocolVersion": .number(1)])
      guard generation == token else {
        await next.stop()
        try? FileManager.default.removeItem(at: directory)
        return
      }
      client = next
      temporary = directory
      connected = true
      await refresh()
    } catch {
      await next.stop()
      try? FileManager.default.removeItem(at: directory)
      if generation == token { status = "环境项目连接失败：\(error.localizedDescription)" }
    }
    if generation == token { loading = false }
  }

  func close() async {
    let token = UUID()
    generation = token
    readRequest = UUID()
    saving = false
    await stopClient()
    guard generation == token else { return }
    projectPath = nil
    files = []
    loading = false
  }

  private func stopClient() async {
    let previous = client
    let directory = temporary
    client = nil
    temporary = nil
    connected = false
    await previous?.stop()
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  func refresh() async {
    guard let client, projectPath != nil, !Task.isCancelled else { return }
    let token = generation
    let request = UUID()
    readRequest = request
    let startingForm = formState
    do {
      let entries = try await client.request("environment.list").decode([LocalEnvironmentEntry].self)
      guard generation == token, readRequest == request, !Task.isCancelled else { return }
      if preserveNewInput(since: startingForm) { return }
      files = entries
      let valid = entries.filter { $0.error == nil }
      let previousFile = fileName
      if !valid.contains(where: { $0.id == fileName }) {
        fileName = valid.first(where: { !$0.inherited && $0.fileName == "environment.toml" })?.id
          ?? valid.first(where: { $0.fileName == "environment.toml" })?.id
          ?? valid.first?.id ?? "environment.toml"
      }
      if fileName != previousFile { clearForm() }
      await load(request: request, startingForm: formState)
    } catch {
      if generation == token, readRequest == request, !Task.isCancelled {
        if preserveNewInput(since: startingForm) { return }
        readError = true
        status = "环境目录读取失败：\(error.localizedDescription)"
      }
    }
  }

  func select(_ id: String) async {
    guard files.contains(where: { $0.id == id }), !Task.isCancelled else { return }
    let changed = fileName != id
    fileName = id
    if changed { clearForm() }
    await load()
  }

  func create() {
    readRequest = UUID()
    let occupied = Set(files.filter { !$0.inherited }.map(\.fileName))
    if !occupied.contains("environment.toml") { fileName = "environment.toml" }
    else {
      var number = 2
      while occupied.contains("environment-\(number).toml") { number += 1 }
      fileName = "environment-\(number).toml"
    }
    clearForm()
    name = projectTitle
    loadedState = formState
    status = "新环境 \(fileName) 尚未保存。"
  }

  private func clearForm() {
    saveConflict = false
    readError = false
    parseError = false
    name = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
    setupScript = ""
    setupPlatforms = .init()
    cleanupScript = ""
    cleanupPlatforms = .init()
    actions = []
    revision = nil
    exists = false
    loadedState = formState
  }

  func load() async {
    guard !Task.isCancelled else { return }
    let request = UUID()
    readRequest = request
    await load(request: request, startingForm: formState)
  }

  private func preserveNewInput(since startingForm: LocalEnvironmentFormState) -> Bool {
    guard formState != startingForm else { return false }
    readRequest = UUID()
    status = "载入期间内容已修改，已保留当前编辑。"
    return true
  }

  private func load(request: UUID, startingForm: LocalEnvironmentFormState) async {
    guard readRequest == request, !Task.isCancelled else { return }
    if preserveNewInput(since: startingForm) { return }
    guard let client else { return }
    let token = generation
    let selected = fileName
    do {
      let result = try await client.request("environment.load", ["fileName": .string(selected)])
      guard generation == token, readRequest == request, fileName == selected, !Task.isCancelled else { return }
      if preserveNewInput(since: startingForm) { return }
      clearForm()
      exists = result["exists"].boolean == true
      revision = result["revision"].text
      if exists, result["error"].text == nil {
        let config = result["config"]
        name = config["name"].text ?? name
        setupScript = config["setup"]["script"].text ?? ""
        setupPlatforms = platformScripts(from: config["setup"])
        cleanupScript = config["cleanup"]["script"].text ?? ""
        cleanupPlatforms = platformScripts(from: config["cleanup"])
        actions = config["actions"].items.map { action in
          EnvironmentAction(title: action["name"].text ?? "",
            symbol: action["icon"].text ?? "tool", script: action["command"].text ?? "",
            platform: EnvironmentPlatform(rawValue: action["platform"].text ?? "all") ?? .all)
        }
        status = "已载入 \(selected)。"
      } else if exists {
        parseError = true
        status = "环境文件无法解析。编辑并保存可替换该文件。"
      } else { status = "\(selected) 尚未创建。" }
      loadedState = formState
    } catch {
      if generation == token, readRequest == request, fileName == selected, !Task.isCancelled {
        if preserveNewInput(since: startingForm) { return }
        clearForm()
        readError = true
        status = "环境文件读取失败：\(error.localizedDescription)"
      }
    }
  }

  func reloadFromSettings() async -> Bool {
    guard connected, let path = projectPath, !Task.isCancelled else { return false }
    let token = generation, selected = fileName, request = UUID()
    readRequest = request
    await load(request: request, startingForm: formState)
    return generation == token && readRequest == request && projectPath == path && fileName == selected
      && connected && !hasUnsavedChanges && !readError && !parseError && !Task.isCancelled
  }

  /// Returns whether the settings editor may return to its overview.
  func saveFromSettings(synchronize: (String, String, Bool) async -> Bool) async -> Bool {
    let created = !exists, selected = fileName
    let token = generation
    guard !Task.isCancelled, let path = projectPath, await save() else { return false }
    let request = readRequest
    let synchronized = await synchronize(path, selected, created)
    guard generation == token, readRequest == request, projectPath == path,
      fileName == selected, connected, !Task.isCancelled else { return false }
    if !synchronized {
      status = "环境文件已保存，但无法选中它。请重新载入项目环境后重试。"
      return false
    }
    if hasUnsavedChanges { status = "已保存提交的内容；当前还有未保存的修改。" }
    return !hasUnsavedChanges
  }

  @discardableResult func save() async -> Bool {
    guard let client, canSave, !Task.isCancelled else { return false }
    let token = generation
    let selected = fileName
    let submitted = formState
    let validName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !validName.isEmpty else { status = "请填写环境名称。"; return false }
    guard actions.allSatisfy(\.isRunnable) else {
      status = "请为每个操作填写名称和命令。"
      return false
    }
    let request = UUID()
    readRequest = request
    let isCurrent = { self.generation == token && self.readRequest == request && self.fileName == selected && self.connected }
    saving = true
    defer { if generation == token { saving = false } }
    var config: [String: JSONValue] = [
      "version": .number(1), "name": .string(validName),
      "setup": .object(platformScripts(setupScript, setupPlatforms)),
    ]
    if !cleanupScript.isEmpty || cleanupPlatforms != .init() {
      config["cleanup"] = .object(platformScripts(cleanupScript, cleanupPlatforms))
    }
    config["actions"] = .array(actions.map { action in
      var fields: [String: JSONValue] = [
        "name": .string(action.title.trimmingCharacters(in: .whitespacesAndNewlines)),
        "command": .string(action.script.trimmingCharacters(in: .whitespacesAndNewlines)),
        "icon": .string(action.symbol),
      ]
      if action.platform != .all { fields["platform"] = .string(action.platform.rawValue) }
      return .object(fields)
    })
    do {
      let result = try await client.request("environment.save", [
        "fileName": .string(selected),
        "expectedRevision": revision.map(JSONValue.string) ?? .null,
        "config": .object(config),
      ])
      guard isCurrent() else { return false }
      revision = result["revision"].text
      exists = result["exists"].boolean == true
      saveConflict = false
      parseError = false
      loadedState = submitted
      status = hasUnsavedChanges ? "已保存提交的内容；当前还有未保存的修改。" : "已保存至项目共享环境文件。"
      if let entries = try? await client.request("environment.list")
        .decode([LocalEnvironmentEntry].self) {
        if isCurrent() { files = entries }
      }
      return isCurrent()
    } catch {
      if isCurrent() {
        if let failure = error as? AgentFailure,
          failure.message == "environment file changed outside ShipiOS; reload before saving" {
          saveConflict = true
          status = "此环境文件已在磁盘上更改。放弃当前修改并重新载入后才能继续保存。"
        } else { status = "共享环境保存失败：\(error.localizedDescription)" }
      }
      return false
    }
  }
}

enum WorktreeEnvironmentChoice {
  static let none = "__none__"
  static let legacy = "__legacy__"
}

struct LocalEnvironmentFormState: Equatable {
  var name: String
  var setup: String
  var setupPlatforms: EnvironmentPlatformScripts
  var cleanup: String
  var cleanupPlatforms: EnvironmentPlatformScripts
  var actions: [EnvironmentAction]
}

extension LocalEnvironmentFormState {
  init(config: JSONValue, fallbackName: String) {
    self.init(name: config["name"].text ?? fallbackName,
      setup: config["setup"]["script"].text ?? "", setupPlatforms: platformScripts(from: config["setup"]),
      cleanup: config["cleanup"]["script"].text ?? "", cleanupPlatforms: platformScripts(from: config["cleanup"]),
      actions: config["actions"].items.map { action in
        EnvironmentAction(title: action["name"].text ?? "", symbol: action["icon"].text ?? "tool",
          script: action["command"].text ?? "",
          platform: EnvironmentPlatform(rawValue: action["platform"].text ?? "all") ?? .all)
      })
  }
}

@MainActor
extension WorkspaceStore {
  func environmentSettingsDidSave(projectPath path: String, fileName: String,
    created: Bool) async -> Bool {
    if project?.path == path && connected {
      let token = session
      await refreshSharedEnvironments()
      guard session == token, project?.path == path, connected, !preparingProjectScope else { return false }
      guard created else { return true }
      guard environmentFiles.contains(where: { $0.id == fileName && $0.error == nil }) else {
        return false
      }
      await selectSharedEnvironment(fileName)
      guard session == token, project?.path == path, connected, !preparingProjectScope,
        environmentFileName == fileName, environmentExists else { return false }
    } else if created {
      var profile = library.profiles[path] ?? BuildProfile()
      profile.environmentFileName = fileName
      library.profiles[path] = profile
    }
    guard created else { return true }
    library.newTaskEnvironmentSelections[path] = fileName
    return saveLibrary()
  }

  func refreshEnvironmentCatalog() async {
    guard !environmentCatalogLoading else { return }
    let paths = library.orderedProjects
    let request = UUID()
    environmentCatalogRequest = request
    environmentCatalog = [:]
    environmentCatalogErrors = [:]
    guard !paths.isEmpty else { environmentCatalogLoading = false; return }
    environmentCatalogLoading = true
    let browser = AgentClient()
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("shipios-environment-catalog-\(UUID())", isDirectory: true)
    do {
      guard let seed = paths.first(where: { path in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: library.primaryFolder(for: path), isDirectory: &isDirectory)
          && isDirectory.boolValue
      }) else { throw AgentFailure(message: "没有可读取的项目目录。") }
      try browser.start(executable: executable, project: URL(fileURLWithPath: library.primaryFolder(for: seed)),
        dataDirectory: temporary)
      _ = try await browser.request("initialize", ["protocolVersion": .number(1)])
      for path in paths {
        guard environmentCatalogRequest == request else { break }
        do {
          let result = try await browser.request("environment.list",
            ["projectPath": .string(library.primaryFolder(for: path))])
          let entries = try result.decode([LocalEnvironmentEntry].self)
          if environmentCatalogRequest == request { environmentCatalog[path] = entries }
        } catch {
          if environmentCatalogRequest == request {
            environmentCatalogErrors[path] = error.localizedDescription
          }
        }
      }
    } catch {
      if environmentCatalogRequest == request {
        for path in paths where environmentCatalog[path] == nil {
          environmentCatalogErrors[path] = error.localizedDescription
        }
      }
    }
    await browser.stop()
    try? FileManager.default.removeItem(at: temporary)
    if environmentCatalogRequest == request { environmentCatalogLoading = false }
  }

  func managedEnvironmentSnapshot(selectionID: String) async throws -> ManagedEnvironmentSnapshot {
    guard connected, let project else { throw AgentFailure(message: "项目环境尚未连接。") }
    if selectionID == WorktreeEnvironmentChoice.none { return .none }
    if selectionID == WorktreeEnvironmentChoice.legacy {
      let profile = library.profiles[project.path] ?? BuildProfile()
      return ManagedEnvironmentSnapshot(fileName: nil, name: "ShipiOS 本地配置", disabled: false,
        setupScript: profile.worktreeSetupScript, setupPlatforms: profile.setupPlatformScripts,
        cleanupScript: profile.worktreeCleanupScript, cleanupPlatforms: profile.cleanupPlatformScripts,
        actions: profile.actions)
    }
    guard environmentFiles.contains(where: { $0.id == selectionID && $0.error == nil }) else {
      throw AgentFailure(message: "所选本地环境已不可用，请刷新环境列表后重试。")
    }
    let loaded = try await client.request("environment.load", ["fileName": .string(selectionID)])
    return try decodeManagedEnvironment(selectionID: selectionID, loaded: loaded)
  }

  var currentEnvironmentFormState: LocalEnvironmentFormState {
    LocalEnvironmentFormState(name: environmentName, setup: worktreeSetupScript,
      setupPlatforms: setupPlatformScripts, cleanup: worktreeCleanupScript,
      cleanupPlatforms: cleanupPlatformScripts, actions: environmentActions)
  }

  var environmentHasUnsavedChanges: Bool {
    environmentLoadedState.map { $0 != currentEnvironmentFormState } ?? false
  }

  private func clearEnvironmentForm(for fileName: String) {
    environmentName = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
    worktreeSetupScript = ""
    setupPlatformScripts = .init()
    worktreeCleanupScript = ""
    cleanupPlatformScripts = .init()
    environmentActions = []
    environmentLoadedState = currentEnvironmentFormState
  }

  func refreshSharedEnvironments() async {
    guard connected, !preparingProjectScope, let path = project?.path, !Task.isCancelled else { return }
    let token = session, request = UUID()
    environmentReadRequest = request
    let startingForm = currentEnvironmentFormState
    do {
      let entries = try await client.request("environment.list").decode([LocalEnvironmentEntry].self)
      guard environmentReadIsCurrent(request, session: token, path: path) else { return }
      if preserveNewEnvironmentInput(since: startingForm) { return }
      environmentFiles = entries
      let valid = entries.filter { $0.error == nil }
      let previousFile = environmentFileName
      if !valid.contains(where: { $0.id == environmentFileName }) {
        environmentFileName = valid.first(where: { !$0.inherited && $0.fileName == "environment.toml" })?.id
          ?? valid.first(where: { $0.fileName == "environment.toml" })?.id
          ?? valid.first?.id ?? "environment.toml"
      }
      if environmentFileName != previousFile { environmentRevision = nil; environmentExists = false }
      await loadSharedEnvironment(request: request, startingForm: currentEnvironmentFormState)
    } catch {
      guard environmentReadIsCurrent(request, session: token, path: path) else { return }
      if preserveNewEnvironmentInput(since: startingForm) { return }
      environmentStatus = "环境目录读取失败：\(error.localizedDescription)"
    }
  }

  func loadSharedEnvironment() async {
    guard !Task.isCancelled else { return }
    let request = UUID()
    environmentReadRequest = request
    await loadSharedEnvironment(request: request, startingForm: currentEnvironmentFormState)
  }

  private func environmentReadIsCurrent(_ request: UUID, session token: UUID, path: String) -> Bool {
    session == token && environmentReadRequest == request && project?.path == path
      && connected && !preparingProjectScope && !Task.isCancelled
  }

  private func preserveNewEnvironmentInput(since startingForm: LocalEnvironmentFormState) -> Bool {
    guard currentEnvironmentFormState != startingForm else { return false }
    environmentReadRequest = UUID()
    environmentStatus = "载入期间内容已修改，已保留当前编辑。"
    return true
  }

  private func loadSharedEnvironment(request: UUID, startingForm: LocalEnvironmentFormState) async {
    guard connected, !preparingProjectScope, let path = project?.path,
      environmentReadRequest == request, !Task.isCancelled else { return }
    if preserveNewEnvironmentInput(since: startingForm) { return }
    let token = session
    let fileName = environmentFileName
    do {
      let result = try await client.request("environment.load", ["fileName": .string(fileName)])
      guard environmentReadIsCurrent(request, session: token, path: path), environmentFileName == fileName else { return }
      if preserveNewEnvironmentInput(since: startingForm) { return }
      environmentExists = result["exists"].boolean == true
      environmentRevision = result["revision"].text
      if environmentExists {
        if result["error"].text != nil {
          clearEnvironmentForm(for: fileName)
          environmentStatus = "环境文件无法解析。编辑并保存可替换该文件。"
          return
        }
        let form = LocalEnvironmentFormState(config: result["config"], fallbackName: environmentName)
        environmentName = form.name; worktreeSetupScript = form.setup; setupPlatformScripts = form.setupPlatforms
        worktreeCleanupScript = form.cleanup; cleanupPlatformScripts = form.cleanupPlatforms
        environmentActions = form.actions
        saveProfile()
        environmentStatus = "已载入 \(fileName)。"
      } else {
        environmentStatus = "\(fileName) 尚未创建；保存后可在 Codex 中使用。"
      }
      environmentLoadedState = currentEnvironmentFormState
    } catch {
      guard environmentReadIsCurrent(request, session: token, path: path), environmentFileName == fileName else { return }
      if preserveNewEnvironmentInput(since: startingForm) { return }
      environmentRevision = nil; environmentExists = false
      clearEnvironmentForm(for: fileName)
      environmentStatus = "共享环境文件读取失败：\(error.localizedDescription)"
    }
  }

  func selectSharedEnvironment(_ fileName: String) async {
    guard let entry = environmentFiles.first(where: { $0.id == fileName }), !Task.isCancelled else { return }
    let token = session, request = UUID()
    environmentReadRequest = request
    if environmentFileName != fileName { environmentRevision = nil; environmentExists = false }
    environmentFileName = fileName
    await loadSharedEnvironment(request: request, startingForm: currentEnvironmentFormState)
    if entry.error == nil, session == token, environmentReadRequest == request, !Task.isCancelled { saveProfile() }
  }

  func createSharedEnvironment() {
    environmentReadRequest = UUID()
    let occupied = Set(environmentFiles.filter { !$0.inherited }.map(\.fileName))
    let next: String
    if !occupied.contains("environment.toml") { next = "environment.toml" }
    else {
      var number = 2
      while occupied.contains("environment-\(number).toml") { number += 1 }
      next = "environment-\(number).toml"
    }
    environmentFileName = next
    environmentName = project.map { library.projectTitle($0.path) } ?? ""
    worktreeSetupScript = ""
    setupPlatformScripts = .init()
    worktreeCleanupScript = ""
    cleanupPlatformScripts = .init()
    environmentActions = []
    environmentExists = false
    environmentRevision = nil
    environmentStatus = "新环境 \(next) 尚未保存。"
    environmentLoadedState = currentEnvironmentFormState
    saveProfile()
  }

  @discardableResult func saveSharedEnvironment() async -> Bool {
    guard connected, !preparingProjectScope, !shuttingDown, let path = project?.path,
      !environmentSaving, !Task.isCancelled else { return false }
    let token = session
    let name = environmentName.trimmingCharacters(in: .whitespacesAndNewlines)
    let fileName = environmentFileName
    let submitted = currentEnvironmentFormState
    guard !name.isEmpty else {
      environmentStatus = "请填写环境名称。"
      return false
    }
    guard environmentActions.allSatisfy(\.isRunnable) else {
      environmentStatus = "请为每个操作填写名称和命令。"
      return false
    }
    let request = UUID()
    environmentReadRequest = request
    let isCurrent = {
      self.session == token && self.environmentReadRequest == request && self.project?.path == path
        && self.environmentFileName == fileName && self.connected && !self.preparingProjectScope && !self.shuttingDown
    }
    environmentSaving = true
    defer { if session == token { environmentSaving = false } }
    var config: [String: JSONValue] = [
      "version": .number(1), "name": .string(name),
      "setup": .object(platformScripts(worktreeSetupScript, setupPlatformScripts)),
    ]
    let cleanup = platformScripts(worktreeCleanupScript, cleanupPlatformScripts)
    if !worktreeCleanupScript.isEmpty || cleanupPlatformScripts != .init() {
      config["cleanup"] = .object(cleanup)
    }
    config["actions"] = .array(environmentActions.map { action in
      let title = action.title.trimmingCharacters(in: .whitespacesAndNewlines)
      let script = action.script.trimmingCharacters(in: .whitespacesAndNewlines)
      var fields: [String: JSONValue] = [
        "name": .string(title), "command": .string(script), "icon": .string(action.symbol),
      ]
      if action.platform != .all { fields["platform"] = .string(action.platform.rawValue) }
      return .object(fields)
    })
    do {
      let result = try await client.request("environment.save", [
        "fileName": .string(fileName),
        "expectedRevision": environmentRevision.map(JSONValue.string) ?? .null,
        "config": .object(config),
      ])
      guard isCurrent() else { return false }
      environmentRevision = result["revision"].text
      environmentExists = result["exists"].boolean == true
      environmentLoadedState = submitted
      environmentStatus = environmentHasUnsavedChanges ? "已保存提交的内容；当前还有未保存的修改。" : "已保存至项目共享环境文件。"
      saveProfile()
      if let entries = try? await client.request("environment.list")
        .decode([LocalEnvironmentEntry].self) {
        if isCurrent() { environmentFiles = entries }
      }
      return isCurrent()
    } catch {
      guard isCurrent() else { return false }
      environmentStatus = "共享环境保存失败：\(error.localizedDescription)"
      return false
    }
  }
}

func decodeManagedEnvironment(selectionID: String, loaded: JSONValue) throws -> ManagedEnvironmentSnapshot {
  guard loaded["exists"].boolean == true else {
    throw AgentFailure(message: "所选本地环境文件已被删除，请刷新后重试。")
  }
  if let error = loaded["error"].text {
    throw AgentFailure(message: "所选本地环境无法解析：\(error)")
  }
  let config = loaded["config"]
  guard let name = config["name"].text, !name.isEmpty else {
    throw AgentFailure(message: "所选本地环境内容无效，请刷新后重试。")
  }
  let actions = config["actions"].items.map { action in
    EnvironmentAction(title: action["name"].text ?? "",
      symbol: action["icon"].text ?? "tool", script: action["command"].text ?? "",
      platform: EnvironmentPlatform(rawValue: action["platform"].text ?? "all") ?? .all)
  }
  return ManagedEnvironmentSnapshot(fileName: selectionID, name: name, disabled: false,
    setupScript: config["setup"]["script"].text ?? "",
    setupPlatforms: platformScripts(from: config["setup"]),
    cleanupScript: config["cleanup"]["script"].text ?? "",
    cleanupPlatforms: platformScripts(from: config["cleanup"]), actions: actions)
}

private func platformScripts(from value: JSONValue) -> EnvironmentPlatformScripts {
  EnvironmentPlatformScripts(
    darwin: value["darwin"]["script"].text ?? "",
    linux: value["linux"]["script"].text ?? "",
    win32: value["win32"]["script"].text ?? "")
}

private func platformScripts(_ script: String, _ overrides: EnvironmentPlatformScripts)
  -> [String: JSONValue]
{
  var fields: [String: JSONValue] = ["script": .string(script)]
  if !overrides.darwin.isEmpty { fields["darwin"] = .object(["script": .string(overrides.darwin)]) }
  if !overrides.linux.isEmpty { fields["linux"] = .object(["script": .string(overrides.linux)]) }
  if !overrides.win32.isEmpty { fields["win32"] = .object(["script": .string(overrides.win32)]) }
  return fields
}
