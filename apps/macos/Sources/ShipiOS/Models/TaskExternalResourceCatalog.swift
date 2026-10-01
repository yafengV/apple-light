import Foundation

/// Merges task resources by both URL and a server-scoped MCP resource identity.
struct TaskExternalResourceCatalog {
  struct Entry {
    var source: TaskExternalSource
    var aliases: Set<String>
    var activitiesByRun: [String: Set<TaskExternalSourceActivity>]
    var hasMCPResource: Bool
    var titlePriority: Int

    var isSource: Bool {
      activitiesByRun.values.contains { activities in
        activities.contains(.provided)
          || activities.contains(.read) && !activities.contains(.created)
      }
    }
    var isArtifact: Bool {
      source.activities.contains(.created) || source.activities.contains(.updated)
    }
  }

  private(set) var entries: [Entry] = []
  var sources: [Entry] { entries.filter(\.isSource) }
  var artifacts: [TaskExternalSource] { entries.filter(\.isArtifact).map(\.source) }

  static func collect<R: Collection>(_ runs: R, library: WorkspaceLibrary) -> Self
    where R.Element == AgentRun {
    var catalog = Self()
    for run in runs {
      if run.kind == "chat" {
        for source in TaskProvidedWebLinks.collect(library.notes[run.id] ?? "") {
          catalog.add(source, activities: [.provided], runID: run.id,
            titlePriority: catalog.isDescriptive(source) ? 1 : 0)
        }
        for message in run.codexSteeredMessages {
          for source in TaskProvidedWebLinks.collect(message.text) {
            catalog.add(source, activities: [.provided], runID: run.id,
              titlePriority: catalog.isDescriptive(source) ? 1 : 0)
          }
        }
      }
      for source in run.codexWebSources {
        catalog.add(source, activities: [.read], runID: run.id)
      }
      for execution in run.toolExecutions where execution.status == .succeeded {
        for resource in execution.mcpResourceActivities
          ?? MCPResourceActivity.extract(from: execution.output,
            serverName: execution.serverName, toolName: execution.toolName) {
          let providerKey = resource.usesProviderID == false ? nil
            : "provider:\(execution.serverID.uuidString):\(resource.id)"
          catalog.add(resource.source, activities: resource.activities, runID: run.id,
            providerKey: providerKey, titlePriority: catalog.isDescriptive(resource.source) ? 2 : 0)
        }
      }
    }
    return catalog
  }

  private func isDescriptive(_ source: CodexWebSource) -> Bool {
    source.title != URL(string: source.url)?.host && !source.title.isEmpty
  }

  private mutating func add(_ resource: CodexWebSource,
    activities: [TaskExternalSourceActivity], runID: String,
    providerKey: String? = nil, titlePriority: Int = 0) {
    guard let urlKey = CodexWebSource.sourceKey(resource.url), !activities.isEmpty else { return }
    var aliases: Set<String> = ["url:\(urlKey)"]
    let canonicalKey = TaskExternalResourceIdentity.canonicalKey(resource.url)
    if let canonicalKey { aliases.insert(canonicalKey) }
    if let providerKey { aliases.insert(providerKey) }
    let matches = entries.indices.filter { !entries[$0].aliases.isDisjoint(with: aliases) }
    if matches.isEmpty {
      entries.append(Entry(source: TaskExternalSource(resource: resource,
        activities: activities.sorted { $0.order < $1.order },
        stableKey: canonicalKey ?? providerKey),
        aliases: aliases, activitiesByRun: [runID: Set(activities)],
        hasMCPResource: providerKey != nil, titlePriority: titlePriority))
      return
    }
    let first = matches[0]
    for index in matches.dropFirst().reversed() {
      let other = entries.remove(at: index)
      entries[first].aliases.formUnion(other.aliases)
      entries[first].hasMCPResource = entries[first].hasMCPResource || other.hasMCPResource
      for (run, values) in other.activitiesByRun {
        entries[first].activitiesByRun[run, default: []].formUnion(values)
      }
      for activity in other.source.activities where !entries[first].source.activities.contains(activity) {
        entries[first].source.activities.append(activity)
      }
      if other.titlePriority >= entries[first].titlePriority {
        entries[first].source.resource = other.source.resource
        entries[first].titlePriority = other.titlePriority
      }
      if entries[first].source.stableKey == nil {
        entries[first].source.stableKey = other.source.stableKey
      }
    }
    entries[first].aliases.formUnion(aliases)
    entries[first].activitiesByRun[runID, default: []].formUnion(activities)
    entries[first].hasMCPResource = entries[first].hasMCPResource || providerKey != nil
    for activity in activities where !entries[first].source.activities.contains(activity) {
      entries[first].source.activities.append(activity)
    }
    entries[first].source.activities.sort { $0.order < $1.order }
    let title = titlePriority >= entries[first].titlePriority
      ? resource.title : entries[first].source.title
    entries[first].source.resource = CodexWebSource(title: title, url: resource.url)
    entries[first].titlePriority = max(entries[first].titlePriority, titlePriority)
    if let canonicalKey { entries[first].source.stableKey = canonicalKey }
    else if let providerKey, !entries[first].source.id.hasPrefix("google:")
      && !entries[first].source.id.hasPrefix("notion:")
      && !entries[first].source.id.hasPrefix("linear:")
      && !entries[first].source.id.hasPrefix("figma:") {
      entries[first].source.stableKey = providerKey
    }
  }
}
