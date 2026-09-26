import AppKit
import SwiftUI

struct SettingsNavigationView: View {
  @Bindable var store: WorkspaceStore
  @State private var query = ""
  @State private var highlightedResultID: String?
  // Preserve native traversal through the form, then include Back and Search
  // when SwiftUI wraps into the sidebar again.
  @State private var exitingSidebar = false
  @State private var searchTabRequest: UUID?
  @FocusState private var focusedPage: SettingsPage?
  @FocusState private var focusedResultID: String?
  @FocusState private var returnFocused: Bool

  private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  private var results: [SettingsSearchResult] {
    SettingsSearch.results(for: query, hasProject: store.project != nil,
      shortcutBindings: Dictionary(uniqueKeysWithValues: DesktopCommand.all.map {
        ($0.id, store.shortcuts.bindings($0.id))
      }), pluginSections: Set(store.visiblePluginSettingsSections),
      agentSandboxMode: store.library.agentRuntimePreferences.sandboxMode)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Keep the header separate from the scrolling navigation. A single
      // sidebar focus section remembers a list anchor after wrapping from the
      // form, so Shift-Tab from Back can incorrectly re-enter the sidebar.
      VStack(alignment: .leading, spacing: 8) {
        Button { store.closeSettings() } label: {
          HStack(spacing: 8) {
            Image(systemName: "arrow.left").frame(width: 16)
            Text("返回应用")
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 8).contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusable().appFont(size: 13)
        .focused($returnFocused)
        .onKeyPress(keys: [.space, .return], phases: .down) { press in
          guard press.modifiers.isEmpty else { return .ignored }
          store.closeSettings()
          return .handled
        }
        .onKeyPress(keys: [.tab], phases: .down) { press in
          guard press.modifiers.isEmpty else { return .ignored }
          store.settingsSearchFocusRequest = UUID()
          return .handled
        }
        .help("返回之前的页面（Esc）").accessibilityLabel("返回应用")

        SettingsSearchInput(query: $query, focusRequest: store.settingsSearchFocusRequest,
          visible: store.destination == .settings, onMove: moveSearchHighlight,
          onSubmit: {
            if let result = results.first(where: { $0.id == highlightedResultID }) {
              reveal(result)
            }
          }, onTab: { backwards in
            if !backwards, searching, results.isEmpty { return false }
            exitingSidebar = false
            focusedPage = nil
            focusedResultID = nil
            returnFocused = false
            let request = UUID()
            searchTabRequest = request
            DispatchQueue.main.async {
              guard searchTabRequest == request, store.destination == .settings, !store.hasSettingsConfirmation,
                store.presentedOverlay == nil else { return }
              searchTabRequest = nil
              if backwards { returnFocused = true }
              else if searching, let first = results.first { focusedResultID = first.id }
              else { focusedPage = SettingsNavigation.pages.first }
            }
            return true
          })
          .frame(height: 28).padding(.bottom, 8)
      }.focusSection()

      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            if searching {
              if results.isEmpty {
                Text("没有匹配的设置").foregroundStyle(.secondary).padding(.vertical, 12)
              } else {
                ForEach(SettingsNavigation.pages) { page in
                  let matches = results.filter { $0.page == page }
                  if !matches.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                      Text(page.title).appFont(size: 10, weight: .semibold)
                        .foregroundStyle(.secondary).padding(.horizontal, 8)
                      ForEach(matches) { searchResultButton($0) }
                    }
                  }
                }
              }
            } else {
              ForEach(SettingsNavigation.groups) { group in
                VStack(alignment: .leading, spacing: 3) {
                  Text(group.title).appFont(size: 10, weight: .semibold)
                    .foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 2)
                  ForEach(group.pages) { navigationButton($0) }
                }
              }
            }
          }.padding(.bottom, 16)
        }
        .onChange(of: focusedPage) { _, page in
          if exitingSidebar, page == SettingsNavigation.pages.first {
            exitingSidebar = false
            returnFocused = true
            return
          }
          if page != nil { exitingSidebar = false }
          if let page { proxy.scrollTo(page) }
        }
        .onChange(of: highlightedResultID) { _, id in
          if let id { proxy.scrollTo(id) }
        }
        .onChange(of: focusedResultID) { _, id in
          if exitingSidebar, id == results.first?.id, id != nil {
            exitingSidebar = false
            returnFocused = true
            return
          }
          if id != nil { exitingSidebar = false }
          if let id { proxy.scrollTo(id) }
        }
      }.focusSection()
    }
    .padding(.horizontal, 12).padding(.top, 16)
    .frame(width: 220).appSidebarSurface()
    .onAppear { store.settingsSearchFocusRequest = UUID() }
    .onDisappear { searchTabRequest = nil }
    .onChange(of: store.settingsSearchFocusRequest) { _, _ in
      exitingSidebar = false
      searchTabRequest = nil
    }
    .onChange(of: query) { _, _ in highlightedResultID = nil; exitingSidebar = false }
  }

  private func navigationButton(_ page: SettingsPage) -> some View {
    Button { select(page) } label: {
      HStack(spacing: 8) {
        Image(systemName: page.icon).frame(width: 16)
        Text(page.title).lineLimit(1)
      }
      .appFont(size: 13)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 8).padding(.vertical, 8)
      .background(
        store.settingsPage == page
          ? Color.primary.opacity(0.08) : .clear,
        in: RoundedRectangle(cornerRadius: 7))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain).focusable().focused($focusedPage, equals: page)
    .onKeyPress(keys: [.space, .return], phases: .down) { press in
      guard press.modifiers.isEmpty else { return .ignored }
      select(page)
      return .handled
    }
    .onKeyPress(keys: [.tab], phases: .down) { press in
      if page == SettingsNavigation.pages.first, press.modifiers == .shift {
        store.settingsSearchFocusRequest = UUID()
        return .handled
      }
      if page == SettingsNavigation.pages.last, press.modifiers.isEmpty {
        exitingSidebar = true
      }
      return .ignored
    }
    .accessibilityLabel(page.title)
    .accessibilityAddTraits(store.settingsPage == page ? .isSelected : [])
    .accessibilityRemoveTraits(store.settingsPage == page ? [] : .isSelected)
    .id(page)
    .onMoveCommand { direction in
      guard acceptsNavigationMove else { return }
      let offset = direction == .down ? 1 : direction == .up ? -1 : 0
      guard offset != 0,
        let next = SettingsNavigation.adjacent(to: page, offset: offset, in: SettingsNavigation.pages)
      else { return }
      select(next)
    }
  }

  private func select(_ page: SettingsPage) {
    exitingSidebar = false
    store.settingsSearchRequest = nil
    // End native popup focus before the old page becomes disabled. Otherwise
    // its responder teardown can cancel the sidebar's SwiftUI focus request.
    if let window = NSApp.keyWindow, window.firstResponder is SettingsMenuControl {
      window.makeFirstResponder(window.contentView)
    }
    store.settingsPage = page
    focusedPage = page
  }

  private func reveal(_ result: SettingsSearchResult) {
    exitingSidebar = false
    store.revealSetting(result)
  }

  private var acceptsNavigationMove: Bool {
    NSApp.currentEvent?.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty != false
  }

  private func moveSearchHighlight(_ direction: MoveCommandDirection) {
    let offset = direction == .down ? 1 : direction == .up ? -1 : 0
    guard searching, offset != 0 else { return }
    if let next = adjacentResultID(to: highlightedResultID, offset: offset) {
      highlightedResultID = next
    }
  }

  private func searchResultButton(_ result: SettingsSearchResult) -> some View {
    Button { reveal(result) } label: {
      Text(result.title)
        .appFont(size: 13).lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(highlightedResultID == result.id ? Color.primary.opacity(0.08) : .clear,
          in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain).focusable().focused($focusedResultID, equals: result.id).id(result.id)
    .onKeyPress(keys: [.space, .return], phases: .down) { press in
      guard press.modifiers.isEmpty else { return .ignored }
      reveal(result)
      return .handled
    }
    .onKeyPress(keys: [.tab], phases: .down) { press in
      if result.id == results.first?.id, press.modifiers == .shift {
        store.settingsSearchFocusRequest = UUID()
        return .handled
      }
      if result.id == results.last?.id, press.modifiers.isEmpty { exitingSidebar = true }
      return .ignored
    }
    .accessibilityLabel("\(result.page.title)：\(result.title)")
    .onHover { if $0 { highlightedResultID = result.id } }
    .onChange(of: focusedResultID) { _, id in
      if id == result.id { highlightedResultID = id }
    }
    .onMoveCommand { direction in
      guard acceptsNavigationMove else { return }
      let offset = direction == .down ? 1 : direction == .up ? -1 : 0
      guard offset != 0, let next = adjacentResultID(to: result.id, offset: offset) else { return }
      focusedResultID = next
      highlightedResultID = next
    }
  }

  private func adjacentResultID(to id: String?, offset: Int) -> String? {
    guard let index = results.firstIndex(where: { $0.id == id }) else {
      return offset < 0 ? results.last?.id : results.first?.id
    }
    let next = index + offset
    return results.indices.contains(next) ? results[next].id : nil
  }

}
