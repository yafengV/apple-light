import SwiftUI
import UniformTypeIdentifiers

struct ProfileSettingsView: View {
  @Bindable var store: WorkspaceStore
  @State private var confirmingAvatarRemoval = false
  @State private var card: ProfileCardDocument?
  @State private var exportingCard = false
  @State private var exportStatus: String?

  var body: some View {
    Form {
      Section("个人资料") {
        HStack(alignment: .top, spacing: 18) {
          avatar
          VStack(alignment: .leading, spacing: 10) {
            TextField("显示名称", text: $store.profileNameDraft).settingsSearchTarget(.profileName)
              .disabled(!store.profileLoaded)
            TextField("用户名", text: $store.profileUsernameDraft).settingsSearchTarget(.profileUsername)
              .disabled(!store.profileLoaded)
            Text("用户名只能包含字母、数字、句点、下划线和连字符。")
              .appFont(.caption).foregroundStyle(.secondary)
            HStack {
              Button("保存资料") { _ = store.saveUserProfile() }
                .disabled(!store.profileLoaded || !profileChanged)
              Button("选择头像…") { store.chooseProfileAvatar() }.settingsSearchTarget(.profileAvatar)
                .disabled(!store.profileLoaded)
              if store.profile.hasAvatar {
                Button("移除头像…", role: .destructive) { confirmingAvatarRemoval = true }
              }
            }
          }
        }.padding(.vertical, 6)
        Text("资料仅保存在当前 ShipiOS 数据目录，不代表 ChatGPT 账号或订阅身份。")
          .appFont(.caption).foregroundStyle(.secondary)
      }

      Section("活动洞察") {
        let activity = store.profileActivity
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) {
          GridRow {
            metric("终身 token", activity.lifetimeTokens.formatted(), "sum")
            metric("单次峰值", activity.peakTokens.formatted(), "chart.line.uptrend.xyaxis")
          }
          GridRow {
            metric("连续活跃", "\(activity.activeStreak) 天", "flame")
            metric("任务 / 回合", "\(activity.taskCount) / \(activity.turnCount)", "bubble.left.and.bubble.right")
          }
        }
        LabeledContent("最长任务") {
          if let title = activity.longestTaskTitle {
            VStack(alignment: .trailing) {
              Text(title).lineLimit(1)
              Text(formattedDuration(activity.longestTaskDuration))
                .appFont(.caption).foregroundStyle(.secondary)
            }
          } else { Text("暂无数据").foregroundStyle(.secondary) }
        }
        Text("token 仅统计独立 API 实际返回的用量；本地构建和缺少 usage 的会话不会被估算。")
          .appFont(.caption).foregroundStyle(.secondary)
      }

      Section("个人资料卡") {
        HStack {
          VStack(alignment: .leading, spacing: 5) {
            Text(store.profile.displayName.isEmpty ? "ShipiOS 用户" : store.profile.displayName)
              .appFont(.headline)
            Text("终身 \(store.profileActivity.lifetimeTokens.formatted()) token · 连续 \(store.profileActivity.activeStreak) 天")
              .appFont(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button("保存资料卡…") { prepareCard() }.settingsSearchTarget(.profileCard).disabled(!store.profileLoaded)
        }.padding(.vertical, 5)
        if let exportStatus { Text(exportStatus).appFont(.caption).textSelection(.enabled) }
      }

      if let error = store.profileError {
        Section {
          Text(error).foregroundStyle(.red).textSelection(.enabled)
          Button("重新加载") { Task { await store.loadProfile() } }.disabled(store.profileLoading)
        }
      }
    }.settingsFormStyle().appSurface()
      .confirmationDialog("移除个人头像？", isPresented: $confirmingAvatarRemoval, titleVisibility: .visible) {
        Button("移除", role: .destructive) { _ = store.removeProfileAvatar() }
        Button("取消", role: .cancel) {}
      } message: { Text("这会删除 ShipiOS 当前数据目录中的头像副本。") }
      .fileExporter(
        isPresented: $exportingCard, document: card, contentType: .png,
        defaultFilename: "ShipiOS-profile-card"
      ) { result in
        switch result {
        case .success: exportStatus = "已保存个人资料卡。"
        case .failure(let error): exportStatus = "保存失败：" + error.localizedDescription
        }
        card = nil
      }
  }

  private var profileChanged: Bool {
    store.profileNameDraft != store.profile.displayName
      || store.profileUsernameDraft != store.profile.username
  }

  @ViewBuilder private var avatar: some View {
    if let image = store.profileAvatar {
      Image(nsImage: image).resizable().scaledToFill().frame(width: 84, height: 84)
        .clipShape(Circle()).id(store.profileAvatarVersion)
    } else {
      Text(store.profile.initials).appFont(size: 28, weight: .semibold).foregroundStyle(.white)
        .frame(width: 84, height: 84).background(.blue.gradient, in: Circle())
    }
  }

  private func metric(_ title: String, _ value: String, _ icon: String) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Label(title, systemImage: icon).appFont(.caption).foregroundStyle(.secondary)
      Text(value).appFont(size: 22, weight: .semibold)
    }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
      .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
  }

  private func formattedDuration(_ interval: TimeInterval) -> String {
    let totalSeconds = max(0, Int(interval.rounded()))
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let seconds = totalSeconds % 60
    if hours > 0 { return "\(hours)小时 \(minutes)分钟" }
    if minutes > 0 { return "\(minutes)分钟 \(seconds)秒" }
    return "\(seconds)秒"
  }

  private func prepareCard() {
    do {
      card = ProfileCardDocument(
        data: try ProfileCardRenderer.render(profile: store.profile, activity: store.profileActivity))
      exportingCard = true
      exportStatus = nil
    } catch { exportStatus = "生成失败：" + error.localizedDescription }
  }
}

private struct ProfileCardDocument: FileDocument {
  static let readableContentTypes: [UTType] = [.png]
  let data: Data
  init(data: Data) { self.data = data }
  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
