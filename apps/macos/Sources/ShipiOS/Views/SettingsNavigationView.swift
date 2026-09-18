import SwiftUI

struct SettingsNavigationView: View {
  @Bindable var store: WorkspaceStore
  @State private var query = ""
  @State private var highlightedResultID: String?
  @FocusState private var focusedPage: SettingsPage?
  @FocusState private var focusedResultID: String?

  private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  private var results: [SettingsSearchResult] {
    SettingsSearch.results(for: query, hasProject: store.project != nil,
      shortcutBindings: Dictionary(uniqueKeysWithValues: DesktopCommand.all.map {
        ($0.id, store.shortcuts.bindings($0.id))
      }), pluginSections: Set(store.visiblePluginSettingsSections))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button { store.closeSettings() } label: {
        HStack(spacing: 8) {
          Image(systemName: "arrow.left").frame(width: 16)
          Text("返回应用")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8).contentShape(Rectangle())
      }
      .buttonStyle(.plain).appFont(size: 13)
      .help("返回之前的页面（Esc）").accessibilityLabel("返回应用")

      SettingsSearchInput(query: $query, focusRequest: store.settingsSearchFocusRequest,
        visible: store.destination == .settings, onMove: moveSearchHighlight,
        onSubmit: {
          if let result = results.first(where: { $0.id == highlightedResultID }) {
            store.revealSetting(result)
          }
        })
        .frame(height: 28).padding(.bottom, 8)

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 16) {
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
          if let page { proxy.scrollTo(page) }
        }
        .onChange(of: highlightedResultID) { _, id in
          if let id { proxy.scrollTo(id) }
        }
        .onChange(of: focusedResultID) { _, id in
          if let id { proxy.scrollTo(id) }
        }
      }
    }
    .padding(.horizontal, 12).padding(.top, 16)
    .frame(width: 220).appSidebarSurface()
    .onAppear { store.settingsSearchFocusRequest = UUID() }
    .onChange(of: query) { _, _ in highlightedResultID = nil }
  }

  private func navigationButton(_ page: SettingsPage) -> some View {
    Button { select(page, focusNavigation: true) } label: {
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
    .buttonStyle(.plain).focused($focusedPage, equals: page)
    .accessibilityLabel(page.title)
    .accessibilityAddTraits(store.settingsPage == page ? .isSelected : [])
    .accessibilityRemoveTraits(store.settingsPage == page ? [] : .isSelected)
    .id(page)
    .onMoveCommand { direction in
      let offset = direction == .down ? 1 : direction == .up ? -1 : 0
      guard offset != 0,
        let next = SettingsNavigation.adjacent(to: page, offset: offset, in: SettingsNavigation.pages)
      else { return }
      select(next, focusNavigation: true)
    }
  }

  private func select(_ page: SettingsPage, focusNavigation: Bool) {
    store.settingsSearchRequest = nil
    store.settingsPage = page
    if focusNavigation {
      // SwiftUI button focus does not reliably end the embedded NSSearchField's
      // field-editor session. End that session before focusing navigation.
      if let window = NSApp?.keyWindow { window.makeFirstResponder(window.contentView) }
      focusedPage = page
    }
  }

  private func moveSearchHighlight(_ direction: MoveCommandDirection) {
    let offset = direction == .down ? 1 : direction == .up ? -1 : 0
    guard searching, offset != 0 else { return }
    if let next = adjacentResultID(to: highlightedResultID, offset: offset) {
      highlightedResultID = next
    }
  }

  private func searchResultButton(_ result: SettingsSearchResult) -> some View {
    Button { store.revealSetting(result) } label: {
      Text(result.title)
        .appFont(size: 13).lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(highlightedResultID == result.id ? Color.primary.opacity(0.08) : .clear,
          in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain).focused($focusedResultID, equals: result.id).id(result.id)
    .accessibilityLabel("\(result.page.title)：\(result.title)")
    .onHover { if $0 { highlightedResultID = result.id } }
    .onChange(of: focusedResultID) { _, id in
      if id == result.id { highlightedResultID = id }
    }
    .onMoveCommand { direction in
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
