import SwiftUI

struct ConnectionSettingsView: View {
  @Bindable var store: WorkspaceStore

  var body: some View {
    SettingsScrollPage(title: SettingsPage.connections.title, actions: {}, controls: {}) {
      Picker("连接", selection: $store.connectionSettingsSection) {
        ForEach(ConnectionSettingsSection.allCases) { Text($0.title).tag($0) }
      }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 520)
      switch store.connectionSettingsSection {
      case .thisMac:
        GroupBox("此 Mac 上的 ShipiOS") {
          VStack(alignment: .leading, spacing: 10) {
            Label("本地运行时已启用", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Text("项目、凭据、终端和执行状态保留在这台 Mac 的 ShipiOS 独立目录中。")
              .foregroundStyle(.secondary)
            Text("跨设备安全中继尚未接入。")
              .appFont(.caption).foregroundStyle(.secondary)
          }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        .settingsSearchTarget(.connectionThisMac)
      case .devices:
        ContentUnavailableView(
          "尚未连接其他设备", systemImage: "macbook.and.iphone",
          description: Text("ShipiOS 尚未接入账户中继，当前不能从其他设备控制这台 Mac。"))
          .settingsSearchTarget(.connectionDevices)
      case .ssh:
        sshContent
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
      .task(id: store.settingsPage) {
        if store.settingsPage == .connections, !store.sshHostsLoaded { await store.loadSSHHosts() }
      }
  }

  @ViewBuilder private var sshContent: some View {
    HStack {
      Text("来自 ~/.ssh/config 的显式主机").appFont(.headline).settingsSearchTarget(.connectionSSH)
      Spacer()
      Button("重新扫描") { Task { await store.loadSSHHosts() } }.disabled(store.sshHostsLoading)
    }
    Text("ShipiOS 只列出不含通配符的 Host 别名，并通过 OpenSSH 解析有效配置。测试连接使用 BatchMode，不会要求或保存密码。")
      .appFont(.caption).foregroundStyle(.secondary)
    if store.sshHostsLoading {
      ProgressView("正在读取 SSH 配置…").frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if store.sshHosts.isEmpty {
      ContentUnavailableView(
        "没有 SSH 主机", systemImage: "network",
        description: Text("先在 ~/.ssh/config 中添加显式 Host 别名，再重新扫描。"))
    } else {
      LazyVStack(spacing: 0) {
        ForEach(store.sshHosts) { host in
        HStack(spacing: 14) {
          Image(systemName: "server.rack").font(.title2).frame(width: 32)
          VStack(alignment: .leading, spacing: 4) {
            Text(host.alias).appFont(.headline)
            Text(host.destination + (host.port.map { ":\($0)" } ?? ""))
              .appFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let status = host.status {
              Text(status).appFont(.caption2)
                .foregroundStyle(status == "连接成功" ? Color.green : Color.orange)
                .lineLimit(2)
            }
          }
          Spacer()
          if store.sshTestingHost == host.alias { ProgressView().controlSize(.small) }
          else {
            Button("测试连接") { Task { await store.testSSHHost(host.alias) } }
          }
        }.padding(.vertical, 6)
        Divider()
        }
      }
    }
    if let error = store.sshHostsError {
      Text(error).foregroundStyle(.red).textSelection(.enabled)
    }
    Text("远程项目选择、远端 App Server 启动、会话迁移和 Handoff 尚未接入。")
      .appFont(.caption).foregroundStyle(.secondary)
  }
}
