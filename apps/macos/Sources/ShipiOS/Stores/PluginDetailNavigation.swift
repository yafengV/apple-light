import Foundation

struct PluginDetailRoute: Equatable {
  let pluginID: String
  let origin: AppDestination
  let settingsPage: SettingsPage
  let settingsReturnDestination: AppDestination
  let pluginSection: PluginSettingsSection
  let pluginQuery: String
}

extension WorkspaceStore {
  var currentPluginDetail: PluginInstallation? {
    guard let id = pluginDetailRoute?.pluginID else { return nil }
    return pluginPreferences.installed.first { $0.id == id }
  }

  var canGoForwardToPluginDetail: Bool {
    guard let route = pluginDetailForwardRoute else { return false }
    return destination == route.origin
      && (destination != .settings || settingsPage == route.settingsPage)
      && pluginPreferences.installed.contains { $0.id == route.pluginID }
  }

  func openPluginDetail(_ id: String) {
    guard destination == .plugins || destination == .settings,
      pluginPreferences.installed.contains(where: { $0.id == id }) else { return }
    pluginDetailRoute = PluginDetailRoute(pluginID: id, origin: destination,
      settingsPage: settingsPage, settingsReturnDestination: settingsReturnDestination,
      pluginSection: pluginSettingsSection, pluginQuery: pluginSettingsQuery)
    pluginDetailForwardRoute = nil
    presentedOverlay = nil
    showingModelPicker = false
    showingBranchPicker = false
    terminalFocusRequest = nil
    destination = .pluginDetail
  }

  func closePluginDetail() {
    guard destination == .pluginDetail, let route = pluginDetailRoute else { return }
    if route.origin == .settings {
      settingsPage = route.settingsPage
      settingsReturnDestination = route.settingsReturnDestination
      pluginSettingsSection = route.pluginSection
      pluginSettingsQuery = route.pluginQuery
    }
    destination = route.origin
    pluginDetailRoute = nil
    pluginDetailForwardRoute = route
  }

  func goForwardToPluginDetail() {
    guard canGoForwardToPluginDetail, let route = pluginDetailForwardRoute else { return }
    openPluginDetail(route.pluginID)
  }
}
