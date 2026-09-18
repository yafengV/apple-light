import SwiftUI

struct PetSettingsView: View {
  @Bindable var store: WorkspaceStore
  @State private var confirmingRemoval = false

  var body: some View {
    Form {
      Section("选择宠物") {
        HStack(spacing: 12) {
          choice(.codey, subtitle: "内置动画伙伴")
          choice(.mini, subtitle: "仅显示聊天控件")
          choice(.custom, subtitle: store.petPreferences.hasCustomPet ? customName : "尚未导入")
        }.settingsSearchTarget(.petChoice)
        Text("选择宠物只会改变外观，不会改变模型或任务行为。")
          .appFont(.caption).foregroundStyle(.secondary)
      }
      Section("浮动宠物") {
        LabeledContent("显示状态") {
          Button(store.petPreferences.visible ? "隐藏宠物" : "显示宠物") {
            _ = store.setPetVisible(!store.petPreferences.visible)
          }.disabled(!store.petsLoaded)
        }
        .settingsSearchTarget(.petVisibility)
        HStack {
          Text("宠物大小")
          Slider(
            value: Binding(
              get: { store.petPreferences.scale },
              set: { _ = store.setPetScale($0) }),
            in: 0.6...1.6, step: 0.05)
          Text("\(Int(store.petPreferences.scale * 100))%")
            .monospacedDigit().frame(width: 42, alignment: .trailing)
          Button("重置") { _ = store.resetPetScale() }
            .disabled(store.petPreferences.scale == 1)
        }
        .settingsSearchTarget(.petSize)
        Text("宠物浮层可拖动，位置、选择、大小和显示状态会随当前 ShipiOS 数据目录保存。按 ⌥Space 或输入 /pet 可显示或隐藏。")
          .appFont(.caption).foregroundStyle(.secondary)
      }
      Section("自定义宠物") {
        HStack {
          Button("导入宠物…") { store.chooseCustomPet() }.settingsSearchTarget(.petImport)
          if store.petPreferences.hasCustomPet {
            Text(customName).foregroundStyle(.secondary)
            Spacer()
            Button("移除…", role: .destructive) { confirmingRemoval = true }
          }
        }
        Text("支持 Codex 兼容的透明 PNG 或 WebP 图集：1536 × 1872 或 v2 1536 × 2288，最大 20 MiB。系统开启“减弱动态效果”时显示静止帧。")
          .appFont(.caption).foregroundStyle(.secondary)
      }
      if let error = store.petError {
        Section {
          Text(error).foregroundStyle(.red).textSelection(.enabled)
          Button("重新加载") { Task { await store.loadPets() } }.disabled(store.petsLoading)
        }
      }
    }.settingsFormStyle().appSurface()
      .confirmationDialog("移除自定义宠物？", isPresented: $confirmingRemoval, titleVisibility: .visible) {
        Button("移除", role: .destructive) { _ = store.removeCustomPet() }
        Button("取消", role: .cancel) {}
      } message: { Text("这会删除当前 ShipiOS 数据目录中的宠物图集副本。") }
  }

  private var customName: String {
    store.petPreferences.customName.isEmpty ? "自定义宠物" : store.petPreferences.customName
  }

  private func choice(_ kind: PetKind, subtitle: String) -> some View {
    Button {
      _ = store.selectPet(kind)
    } label: {
      VStack(spacing: 8) {
        Image(systemName: kind == .mini ? "rectangle.and.pencil.and.ellipsis" : kind == .custom ? "photo" : "sparkles")
          .font(.system(size: 28)).frame(height: 34)
        Text(kind.title).appFont(.headline)
        Text(subtitle).appFont(.caption).foregroundStyle(.secondary).lineLimit(1)
      }.frame(maxWidth: .infinity).padding(.vertical, 14)
        .background(
          store.petPreferences.selected == kind ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035),
          in: RoundedRectangle(cornerRadius: 10))
        .overlay(
          RoundedRectangle(cornerRadius: 10).strokeBorder(
            store.petPreferences.selected == kind ? Color.accentColor : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
    }.buttonStyle(.plain)
      .disabled(kind == .custom && !store.petPreferences.hasCustomPet)
      .accessibilityAddTraits(store.petPreferences.selected == kind ? .isSelected : [])
  }
}
