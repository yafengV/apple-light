import SwiftUI

struct AppshotSettingsView: View {
  @Bindable var store: WorkspaceStore

  var body: some View {
    SettingsScrollPage(title: SettingsPage.appshots.title, actions: {}, controls: {}) {
      VStack(alignment: .leading, spacing: 20) {
        HStack(alignment: .top, spacing: 16) {
          Image(systemName: "macwindow.on.rectangle")
            .font(.system(size: 30, weight: .light))
            .frame(width: 40).accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 6) {
            Text("截取应用快照，向 ShipiOS 展示你最前端的窗口")
              .appFont(size: 18, weight: .semibold)
            Text("应用快照包含视觉和文字内容，包括已滚出视野的文字。")
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 16) {
            controls.frame(minWidth: 340, maxWidth: .infinity)
            AppshotDemoView().frame(minWidth: 340, maxWidth: .infinity)
          }
          VStack(spacing: 16) {
            controls
            AppshotDemoView().frame(maxWidth: 390)
          }
        }
      }
    }
      .onAppear { store.refreshComputerUsePermissions() }
  }

  private var controls: some View {
    VStack(spacing: 0) {
      SettingsMenuPicker("快捷键", description: store.appshotHotkey.explanation,
        selection: Binding(
          get: { store.appshotHotkey },
          set: { store.appshotHotkey = $0 }),
        options: AppshotHotkey.allCases.map {
          SettingsMenuOption(value: $0, title: $0.title)
        })
        .settingsSearchTarget(.appshotHotkey)
        .padding(16)
      if store.appshotHotkey != .none && !store.accessibilityGranted {
        HStack(spacing: 8) {
          Text("在其他应用中使用快捷键需要辅助功能权限。")
            .appFont(.caption).foregroundStyle(.secondary)
          Spacer(minLength: 0)
          Button("打开系统设置") { store.openAccessibilitySettings() }
        }.padding(.horizontal, 16).padding(.bottom, 12)
      }
      Divider().padding(.horizontal, 16)
      AppshotDestinationMenu(store: store)
        .settingsSearchTarget(.appshotDestination)
        .padding(16)
      Divider().padding(.horizontal, 16)
      SettingsToggle(title: "播放音效", description: "截取成功时播放系统提示音。",
        isOn: Binding(
          get: { store.appshotSoundEnabled },
          set: { store.appshotSoundEnabled = $0 }))
        .settingsSearchTarget(.appshotSound)
        .padding(16)
    }
    .toggleStyle(SettingsSwitchStyle())
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
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
