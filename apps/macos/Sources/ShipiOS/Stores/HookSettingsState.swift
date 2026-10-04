import Foundation
import Observation

@MainActor @Observable final class HookSettingsState {
  let root: URL
  var sources: [HookSettingsSource] = []
  var selectedSourceID: String?
  var loading = false
  var busy = false
  var loaded = false
  var error: String?
  var revision = UUID()
  @ObservationIgnored private var generation = UUID()
  init(root: URL) { self.root = root }
  var groups: [HookSettingsGroup] {
    Dictionary(grouping: sources, by: \.pluginID).keys.sorted().map { pluginID in
      HookSettingsGroup(id: pluginID, sources: sources.filter { $0.pluginID == pluginID })
    }
  }
  var selectedGroup: HookSettingsGroup? { groups.first { $0.id == selectedSourceID } }
  var selectedSource: HookSettingsSource? { selectedGroup?.sources.first }

  private func declaredSources() throws -> [HookSettingsSource] {
    let preferences = try PluginStorage.load(root: root)
    let decisions = try HookStateStorage.load(root: root)
    return preferences.installed.filter(\.components.hasHooks).flatMap { plugin in
      do { return try PluginHookCatalog.sources(plugin: plugin, root: root, decisions: decisions) }
      catch {
        return [HookSettingsSource(id: "invalid_" + plugin.id, pluginID: plugin.id,
          name: plugin.name, label: "", fileURL: PluginStorage.packageURL(root: root, id: plugin.id),
          pluginEnabled: plugin.enabled, binding: HookSourceBinding(id: "invalid_" + plugin.id,
            configuration: "{}"), error: error.localizedDescription)]
      }
    }
  }

  func reload(executable: URL) async {
    let token = UUID(); generation = token; loading = true
    defer { if generation == token { loading = false } }
    do {
      var next = try declaredSources()
      for index in next.indices where next[index].error == nil {
        try Task.checkCancellation()
        do {
          let inventory = try await HookInventoryService.inspect([next[index].binding], root: root, executable: executable)
          next[index].hooks = inventory.hooks; next[index].warnings = inventory.warnings
        } catch is CancellationError { throw CancellationError() }
        catch { next[index].error = error.localizedDescription }
      }
      guard generation == token else { return }
      sources = next; loaded = true; error = nil
      if selectedSourceID != nil, selectedSource == nil { selectedSourceID = nil }
    } catch is CancellationError {} catch {
      guard generation == token else { return }; self.error = error.localizedDescription
    }
  }

  func open(_ id: String) {
    guard !busy, !loading else { return }
    let groupID = sources.first { $0.id == id }?.pluginID ?? id
    guard groups.contains(where: { $0.id == groupID }) else { return }
    selectedSourceID = groupID; error = nil
  }
  func close() { guard !busy else { return }; selectedSourceID = nil; error = nil }
  func invalidate() { revision = UUID(); loaded = false }

  /// Re-discover before accepting a UI decision. A reload, package replacement,
  /// or removal cannot authorize a definition that the user has not reviewed.
  func change(sourceID: String, expected: [HookMetadata], enabled: Bool? = nil,
    trust: Bool = false, executable: URL) async {
    guard !busy, !loading, let selected = selectedGroup, !expected.isEmpty,
      selected.id == sourceID || selected.sources.contains(where: { $0.id == sourceID }) else { return }
    busy = true
    defer { busy = false }
    do {
      let fresh = try declaredSources().filter { $0.pluginID == selected.id }
      let required = Set(expected.map(\.sourceId))
      guard required.isSubset(of: Set(fresh.filter { $0.error == nil }.map(\.id))) else {
        throw AgentFailure(message: "Hook 来源已移除或无法读取，请重新加载。")
      }
      let inventory = try await HookInventoryService.inspect(fresh.filter { required.contains($0.id) }.map(\.binding), root: root, executable: executable)
      var changes: HookStateStorage.Decisions = [:]
      for reviewed in expected {
        guard let current = inventory.hooks.first(where: { $0.id == reviewed.id }),
          current.currentHash == reviewed.currentHash, !current.managed else {
          throw AgentFailure(message: "Hook 在审阅后发生变化，请重新加载并检查新定义。")
        }
        if enabled == true, current.needsReview, !trust {
          throw AgentFailure(message: "请先审阅并信任此 Hook。")
        }
        changes[current.sourceId, default: [:]][current.key] = HookDecision(enabled: enabled,
          trustedHash: trust ? current.currentHash : nil)
      }
      try HookStateStorage.update(root: root, changes: changes)
      await reload(executable: executable)
    } catch { self.error = error.localizedDescription }
  }

  func sessionBindings() throws -> [HookSourceBinding] {
    // Re-read both declarations and decisions at each new turn. Disabled
    // packages are absent rather than authorizing their handlers indirectly.
    let sources = try declaredSources().filter(\.pluginEnabled)
    if let invalid = sources.first(where: { $0.error != nil }) {
      throw AgentFailure(message: invalid.error ?? "无法读取 Hook 配置。")
    }
    return sources.map(\.binding)
  }
}
