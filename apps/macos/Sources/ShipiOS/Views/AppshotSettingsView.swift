import SwiftUI

struct AppshotSettingsView: View {
  @Bindable var store: WorkspaceStore

  var body: some View {
    Form {
      Section {
        VStack(alignment: .leading, spacing: 8) {
          Text("截取应用快照，向 ChatGPT 展示你最前端的窗口")
            .appFont(size: 18, weight: .semibold)
          Text("应用快照包含窗口截图；获得辅助功能权限后，还可附带窗口中的文字。")
            .foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      Section("快捷键") {
        SettingsMenuPicker("快捷键", description: store.appshotHotkey.explanation,
          selection: Binding(
            get: { store.appshotHotkey },
            set: { store.appshotHotkey = $0 }),
          options: AppshotHotkey.allCases.map {
            SettingsMenuOption(value: $0, title: $0.title)
          })
          .settingsSearchTarget(.appshotHotkey)
        if store.appshotHotkey != .none && !store.accessibilityGranted {
          HStack {
            Text("在其他应用中使用快捷键需要辅助功能权限。")
              .foregroundStyle(.secondary)
            Spacer()
            Button("打开系统设置") { store.openAccessibilitySettings() }
          }
        }
      }
      Section("发送") {
        AppshotDestinationMenu(store: store)
          .settingsSearchTarget(.appshotDestination)
        SettingsToggle(title: "播放音效", description: "截取成功时播放系统提示音。",
          isOn: Binding(
            get: { store.appshotSoundEnabled },
            set: { store.appshotSoundEnabled = $0 }))
          .settingsSearchTarget(.appshotSound)
      }
    }.settingsFormStyle().appSurface()
      .onAppear { store.refreshComputerUsePermissions() }
  }
}

private struct AppshotDestinationMenu: View {
  @Bindable var store: WorkspaceStore
  @State private var showing = false
  @FocusState private var triggerFocused: Bool

  var body: some View {
    LabeledContent {
      Button {
        showing = true
      } label: {
        HStack(spacing: 10) {
          Text(store.appshotDestination.title)
          Image(systemName: "chevron.up.chevron.down")
            .appFont(.caption).foregroundStyle(.secondary)
        }
      }
      .accessibilityLabel("Appshot 发送目标")
      .focusable().focused($triggerFocused)
      .popover(isPresented: $showing, arrowEdge: .bottom) {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(AppshotDestination.allCases) { destination in
            Button {
              store.appshotDestination = destination
              showing = false
            } label: {
              HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                  Text(destination.title).foregroundStyle(.primary)
                  Text(destination.explanation)
                    .appFont(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if store.appshotDestination == destination {
                  Image(systemName: "checkmark")
                    .accessibilityHidden(true)
                }
              }
              .padding(.horizontal, 10).padding(.vertical, 8)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(store.appshotDestination == destination ? .isSelected : [])
          }
        }
        .frame(width: 320)
        .padding(6)
        .onExitCommand { showing = false }
      }
      .onChange(of: showing) { _, open in
        if !open { triggerFocused = true }
      }
    } label: {
      SettingsControlLabel(title: "Appshot 发送目标",
        description: "选择使用快捷键时将 Appshots 发送到哪里。")
    }
  }
}
