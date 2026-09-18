import AppKit
import SwiftUI

struct ComputerUseSettingsView: View {
  @Bindable var store: WorkspaceStore
  @Environment(\.scenePhase) private var scenePhase
  @State private var applicationToRemove: ComputerUseApplication?

  var body: some View {
    Form {
      Section {
        Text("管理 ShipiOS 如何查看和操作 Mac 上的其他应用。系统权限与应用访问决定彼此独立。")
          .foregroundStyle(.secondary)
      }
      Section("控制") {
        Toggle(
          "任意应用",
          isOn: Binding(
            get: { store.computerUsePreferences.anyAppEnabled },
            set: { _ = store.setAnyAppComputerUse($0) }))
          .disabled(!store.computerUseLoaded).settingsSearchTarget(.anyApplication)
        Text("连接电脑使用运行时后，首次控制应用仍会请求许可；始终允许列表中的应用可跳过该询问。")
          .appFont(.caption).foregroundStyle(.secondary)
        HStack {
          Text("内置浏览器")
          Spacer()
          HStack(spacing: 10) {
            Label("已连接", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Button("管理") { store.openSettings(.browser) }
          }
        }.accessibilityElement(children: .contain)
      }
      Section("macOS 系统访问") {
        permissionRow(
          title: "屏幕录制", detail: "允许 ShipiOS 查看目标应用。",
          granted: store.screenRecordingGranted,
          request: store.requestScreenRecordingAccess,
          openSettings: store.openScreenRecordingSettings).settingsSearchTarget(.screenRecording)
        permissionRow(
          title: "辅助功能", detail: "允许 ShipiOS 点击、输入和导航。",
          granted: store.accessibilityGranted,
          request: store.requestAccessibilityAccess,
          openSettings: store.openAccessibilitySettings).settingsSearchTarget(.accessibility)
        HStack {
          Text("上次检查")
          Spacer()
          Text(store.computerUseLastChecked.formatted(date: .omitted, time: .standard))
            .foregroundStyle(.secondary).monospacedDigit()
          Button("重新检查") { store.refreshComputerUsePermissions() }
        }
      }
      Section("始终允许的应用") {
        if store.computerUsePreferences.alwaysAllowedApplications.isEmpty {
          ContentUnavailableView(
            "没有始终允许的应用", systemImage: "app.dashed",
            description: Text("首次控制应用时仍会请求你的许可。"))
        } else {
          ForEach(store.computerUsePreferences.alwaysAllowedApplications) { application in
            applicationRow(application)
          }
        }
        Button("添加应用…") { store.chooseAlwaysAllowedApplication() }.settingsSearchTarget(.allowedApplications)
          .disabled(!store.computerUseLoaded)
      }
      Section("锁定状态下使用") {
        Toggle("允许在 Mac 锁定时使用电脑", isOn: .constant(false)).disabled(true)
        Text("此功能需要 Apple 授权的系统插件。当前 ShipiOS 构建尚未包含该插件，因此不会在锁定状态下控制应用。")
          .appFont(.caption).foregroundStyle(.secondary)
      }
      if let error = store.computerUseError {
        Section {
          Text(error).foregroundStyle(.red).textSelection(.enabled)
          Button("重新加载") { Task { await store.loadComputerUsePreferences() } }
            .disabled(store.computerUseLoading)
        }
      }
    }.settingsFormStyle().appSurface()
      .task {
        if !store.computerUseLoaded { await store.loadComputerUsePreferences() }
        else { store.refreshComputerUsePermissions() }
      }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { store.refreshComputerUsePermissions() }
      }
      .confirmationDialog(
        "移除始终允许的应用？",
        isPresented: Binding(
          get: { applicationToRemove != nil },
          set: { if !$0 { applicationToRemove = nil } }),
        titleVisibility: .visible
      ) {
        Button("移除", role: .destructive) {
          if let applicationToRemove {
            _ = store.removeAlwaysAllowedApplication(applicationToRemove)
          }
          applicationToRemove = nil
        }
        Button("取消", role: .cancel) { applicationToRemove = nil }
      } message: {
        Text("下次控制该应用时将重新请求许可。")
      }
  }

  private func permissionRow(
    title: String, detail: String, granted: Bool, request: @escaping () -> Void,
    openSettings: @escaping () -> Void
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
          Text(detail).appFont(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Label(
          granted ? "已允许" : "未允许",
          systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        ).foregroundStyle(granted ? .green : .orange)
      }
      HStack {
        Spacer()
        if !granted { Button("请求访问", action: request) }
        Button("打开系统设置", action: openSettings)
      }
    }.padding(.vertical, 3)
  }

  private func applicationRow(_ application: ComputerUseApplication) -> some View {
    HStack(spacing: 12) {
      Image(nsImage: NSWorkspace.shared.icon(forFile: application.path))
        .resizable().frame(width: 32, height: 32)
      VStack(alignment: .leading, spacing: 2) {
        Text(application.name)
        Text(application.bundleIdentifier ?? application.path)
          .appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer()
      Button(role: .destructive) { applicationToRemove = application } label: {
        Image(systemName: "trash")
      }.help("移除始终允许")
    }
  }
}
