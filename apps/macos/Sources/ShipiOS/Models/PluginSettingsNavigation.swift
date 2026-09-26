import Foundation

enum PluginSettingsSection: String, CaseIterable, Identifiable {
  case plugins, mcpServers, skills
  var id: String { rawValue }
  var title: String {
    switch self { case .plugins: "插件"; case .mcpServers: "MCP"; case .skills: "技能" }
  }
  var importField: SettingsSearchField {
    switch self { case .plugins: .pluginsImport; case .mcpServers: .mcpImport; case .skills: .skillsImport }
  }

  func count(in plugins: [PluginInstallation], standaloneSkills: Int = 0) -> Int {
    switch self {
    case .plugins: plugins.count
    case .mcpServers: plugins.reduce(0) { $0 + $1.components.mcpServers }
    case .skills: plugins.reduce(standaloneSkills) { $0 + $1.components.skills }
    }
  }

  static func visible(in plugins: [PluginInstallation], pluginsEnabled: Bool, standaloneSkills: Int = 0) -> [Self] {
    allCases.filter { $0 == .mcpServers || (pluginsEnabled && ($0 == .skills
      || $0.count(in: plugins, standaloneSkills: standaloneSkills) > 0)) }
  }
}

extension WorkspaceStore {
  func reconcilePluginSettingsTarget() {
    if let field = settingsSearchRequest?.result.field,
      let section = field.pluginSection,
      !visiblePluginSettingsSections.contains(section)
        || (field == .skillsInstalled && section.count(in: pluginPreferences.installed,
          standaloneSkills: pluginPreferences.standaloneSkills.count) == 0) {
      settingsSearchRequest = nil
    }
  }
  var visiblePluginSettingsSections: [PluginSettingsSection] {
    PluginSettingsSection.visible(in: pluginPreferences.installed, pluginsEnabled: pluginsEnabled,
      standaloneSkills: pluginPreferences.standaloneSkills.count)
  }
  var activePluginSettingsSection: PluginSettingsSection {
    if !pluginsEnabled { return .mcpServers }
    if pluginsLoading || visiblePluginSettingsSections.contains(pluginSettingsSection) {
      return pluginSettingsSection
    }
    return visiblePluginSettingsSections.first ?? .mcpServers
  }
}

extension SettingsPage {
  /// Old links still resolve, but all extension management uses one settings page.
  var navigationPage: SettingsPage {
    self == .mcpServers || self == .skills ? .plugins : self
  }
  var pluginSection: PluginSettingsSection? {
    switch self { case .mcpServers: .mcpServers; case .skills: .skills; default: nil }
  }
}

extension SettingsSearchField {
  var pluginSection: PluginSettingsSection? {
    switch self {
    case .pluginsImport, .pluginsInstalled: .plugins
    case .mcpImport, .mcpInstalled: .mcpServers
    case .skillsImport, .skillsInstalled: .skills
    default: nil
    }
  }
}
