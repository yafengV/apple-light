import AppKit
import Foundation

extension WorkspaceStore {
  func loadPlugins() async {
    guard !pluginsLoading else { return }
    pluginsLoading = true
    defer { pluginsLoading = false }
    pluginsLoaded = false
    repositorySkillCache.removeAll()
    repositorySkillRevision = UUID()
    let root = dataRoot
    do {
      let loaded = try await Task.detached(priority: .userInitiated) {
        let preferences = try PluginStorage.load(root: root)
        let skills = try PluginStorage.skills(preferences: preferences, root: root)
        let installedSkills = try PluginStorage.skills(preferences: preferences, root: root, includeDisabled: true)
        return (preferences, skills, installedSkills)
      }.value
      pluginPreferences = loaded.0
      pluginSkills = loaded.1
      installedPluginSkills = loaded.2
      pluginsLoaded = true
      pluginsError = nil
    } catch {
      pluginSkills = []
      installedPluginSkills = []
      pluginsError = error.localizedDescription
    }
  }

  func repositorySkills(for projectPath: String) throws -> [PluginSkillReference] {
    guard !projectPath.isEmpty else { return [] }
    if let cached = repositorySkillCache[projectPath] { return cached }
    let loaded = try PluginStorage.repositorySkills(
      project: URL(fileURLWithPath: projectPath, isDirectory: true))
    repositorySkillCache[projectPath] = loaded
    return loaded
  }

  private func refreshRepositorySkills(for projectPath: String) {
    repositorySkillCache.removeValue(forKey: projectPath)
    repositorySkillRevision = UUID()
  }

  @discardableResult func createRepositorySkill(
    id: String, description: String, instructions: String, projectPath: String
  ) -> Bool {
    guard !projectPath.isEmpty, currentProjectKey == projectPath else {
      pluginsError = "项目已切换，请重新选择技能的保存位置。"
      return false
    }
    do {
      try PluginStorage.createRepositorySkill(id: id, description: description,
        instructions: instructions, project: URL(fileURLWithPath: projectPath, isDirectory: true))
      refreshRepositorySkills(for: projectPath)
      pluginsError = nil
      return true
    } catch { pluginsError = error.localizedDescription; return false }
  }

  @discardableResult func updateRepositorySkill(
    id: String, text: String, expectedOriginal: String, project: URL
  ) -> Bool {
    do {
      guard !currentProjectKey.isEmpty,
        try repositorySkills(for: currentProjectKey).contains(where: {
          $0.id == id && $0.repositoryRoot?.standardizedFileURL.path == project.standardizedFileURL.path
        })
      else {
        pluginsError = "项目已切换，请回到可使用此技能的项目后再保存。"
        return false
      }
      try PluginStorage.updateRepositorySkill(id: id, text: text,
        expectedOriginal: expectedOriginal, project: project)
      refreshRepositorySkills(for: currentProjectKey)
      pluginsError = nil
      return true
    } catch { pluginsError = error.localizedDescription; return false }
  }

  func choosePluginFolder() {
    guard pluginsLoaded, let window = NSApp.keyWindow else { return }
    let panel = NSOpenPanel()
    panel.title = "选择包含 plugin.json 或 .codex-plugin/plugin.json 的插件文件夹"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor in
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        _ = self?.installPlugin(from: url)
      }
    }
  }

  @discardableResult func installPlugin(from url: URL) -> Bool {
    guard pluginsLoaded else { return false }
    do {
      pluginPreferences = try PluginStorage.install(from: url, root: dataRoot)
      try refreshPluginSkills()
      pluginsError = nil
      return true
    } catch { pluginsError = error.localizedDescription; return false }
  }

  @discardableResult func setPluginEnabled(_ enabled: Bool, id: String) -> Bool {
    guard pluginsLoaded else { return false }
    do {
      pluginPreferences = try PluginStorage.setEnabled(enabled, id: id, root: dataRoot)
      try refreshPluginSkills()
      pluginsError = nil
      return true
    } catch { pluginsError = error.localizedDescription; return false }
  }

  @discardableResult func removePlugin(_ id: String) -> Bool {
    guard pluginsLoaded else { return false }
    do {
      pluginPreferences = try PluginStorage.remove(id: id, root: dataRoot)
      try refreshPluginSkills()
      pluginsError = nil
      return true
    } catch { pluginsError = error.localizedDescription; return false }
  }

  func revealPlugin(_ id: String) {
    let url = PluginStorage.packageURL(root: dataRoot, id: id)
    guard FileManager.default.fileExists(atPath: url.path) else {
      pluginsError = "插件文件缺失。"
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  func isSkillEnabled(_ skill: PluginSkillReference) -> Bool {
    pluginPreferences.isSkillEnabled(skill)
  }

  @discardableResult func setSkillEnabled(_ enabled: Bool, skill: PluginSkillReference) -> Bool {
    guard skill.isRepository else { return setSkillEnabled(enabled, id: skill.id) }
    guard pluginsLoaded else { return false }
    guard !currentProjectKey.isEmpty else {
      pluginsError = "项目已切换，请回到可使用此技能的项目后再修改启用状态。"
      return false
    }
    do {
      pluginPreferences = try PluginStorage.setRepositorySkillEnabled(enabled, id: skill.id,
        project: URL(fileURLWithPath: currentProjectKey, isDirectory: true), root: dataRoot)
      pluginsError = nil
      return true
    } catch { pluginsError = error.localizedDescription; return false }
  }

  @discardableResult func setSkillEnabled(_ enabled: Bool, id: String) -> Bool {
    guard pluginsLoaded else { return false }
    do {
      pluginPreferences = try PluginStorage.setSkillEnabled(enabled, id: id, root: dataRoot)
      try refreshPluginSkills()
      pluginsError = nil
      return true
    } catch { pluginsError = error.localizedDescription; return false }
  }

  private func refreshPluginSkills() throws {
    let available = try PluginStorage.skills(preferences: pluginPreferences, root: dataRoot)
    let installed = try PluginStorage.skills(preferences: pluginPreferences, root: dataRoot, includeDisabled: true)
    pluginSkills = available
    installedPluginSkills = installed
  }

  func chooseStandaloneSkillFolder() {
    guard pluginsLoaded, let window = NSApp.keyWindow else { return }
    let panel = NSOpenPanel()
    panel.title = "选择包含 SKILL.md 的技能文件夹"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor in
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        _ = self?.installStandaloneSkill(from: url)
      }
    }
  }

  @discardableResult func installStandaloneSkill(from url: URL) -> Bool {
    guard pluginsLoaded else { return false }
    do {
      pluginPreferences = try PluginStorage.installStandaloneSkill(from: url, root: dataRoot)
      try refreshPluginSkills()
      pluginSettingsSection = .skills
      pluginSettingsQuery = ""
      pluginsError = nil
      return true
    } catch { pluginsError = error.localizedDescription; return false }
  }

  @discardableResult func createStandaloneSkill(
    id: String, description: String, instructions: String
  ) -> Bool {
    guard pluginsLoaded else { return false }
    do {
      pluginPreferences = try PluginStorage.createStandaloneSkill(
        id: id, description: description, instructions: instructions, root: dataRoot)
      try refreshPluginSkills()
      pluginsError = nil
      return true
    } catch { pluginsError = error.localizedDescription; return false }
  }

  @discardableResult func updateStandaloneSkill(
    id: String, text: String, expectedOriginal: String
  ) -> Bool {
    guard pluginsLoaded else { return false }
    do {
      try PluginStorage.updateStandaloneSkill(
        id: id, text: text, expectedOriginal: expectedOriginal, root: dataRoot)
      try refreshPluginSkills()
      pluginsError = nil
      return true
    } catch { pluginsError = error.localizedDescription; return false }
  }

  @discardableResult func removeStandaloneSkill(_ id: String) -> Bool {
    guard pluginsLoaded else { return false }
    do {
      pluginPreferences = try PluginStorage.removeStandaloneSkill(id: id, root: dataRoot)
      try refreshPluginSkills()
      pluginsError = nil
      return true
    } catch { pluginsError = error.localizedDescription; return false }
  }
}
