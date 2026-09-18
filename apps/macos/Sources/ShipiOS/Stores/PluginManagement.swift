import AppKit
import Foundation

extension WorkspaceStore {
  func loadPlugins() async {
    guard !pluginsLoading else { return }
    pluginsLoading = true
    defer { pluginsLoading = false }
    pluginsLoaded = false
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
    } catch { pluginsError = error.localizedDescription }
  }

  func choosePluginFolder() {
    guard pluginsLoaded, let window = NSApp.keyWindow else { return }
    let panel = NSOpenPanel()
    panel.title = "选择包含 .codex-plugin/plugin.json 的插件文件夹"
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
