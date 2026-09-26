import AppKit
import SwiftUI

struct PetOverlayView: View {
  @Bindable var store: WorkspaceStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var prompt = ""
  @State private var sending = false

  var body: some View {
    VStack(spacing: store.petPreferences.selected == .mini ? 0 : 6) {
      if store.petPreferences.selected != .mini {
        petVisual.frame(height: 142)
          .accessibilityLabel(store.petPreferences.selected == .custom ? customName : "Codey")
          .accessibilityValue(store.petActivityStatus.title)
      }
      controls
    }
    .padding(store.petPreferences.selected == .mini ? 7 : 10)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(.primary.opacity(0.1)))
    .shadow(color: .black.opacity(0.18), radius: 16, y: 7)
    .padding(10)
    .contextMenu { Button("隐藏宠物") { _ = store.setPetVisible(false) } }
  }

  @ViewBuilder private var petVisual: some View {
    if store.petPreferences.selected == .custom, let image = store.petCustomImage {
      CustomPetAnimation(
        image: image, row: store.petActivityStatus.atlasRow, reduceMotion: reduceMotion
      ).id(store.petAssetVersion)
    } else {
      CodeyPetAnimation(status: store.petActivityStatus, reduceMotion: reduceMotion)
    }
  }

  private var customName: String {
    store.petPreferences.customName.isEmpty ? "自定义宠物" : store.petPreferences.customName
  }

  private var controls: some View {
    HStack(spacing: 7) {
      Button { store.showPetChat() } label: { Image(systemName: "square.and.pencil") }
        .buttonStyle(.borderless).help("开始新会话")
      TextField("快速提问", text: $prompt)
        .textFieldStyle(.plain)
        .disabled(sending)
        .onSubmit { submit() }
      if sending {
        ProgressView().controlSize(.small)
      } else {
        Button(action: submit) { Image(systemName: "arrow.up.circle.fill") }
          .buttonStyle(.borderless).disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      Menu {
        if store.attentionTasks.isEmpty, store.activeRun == nil, !store.hasLiveModelRequests {
          Text("没有待处理活动")
        }
        if let task = store.selectedTask, store.selectedActiveRun != nil,
          store.taskAttentionKind(for: task) == nil {
          Button("运行中：" + task.title) { store.selectTask(task); NSApp.activate(ignoringOtherApps: true) }
        }
        ForEach(store.attentionTasks) { task in
          Button("\(store.taskAttentionKind(for: task)?.title ?? "需关注")：\(task.title)") {
            store.selectTask(task); NSApp.activate(ignoringOtherApps: true)
          }
        }
      } label: {
        Image(systemName: store.attentionTasks.isEmpty ? "bell" : "bell.badge.fill")
      }.menuStyle(.borderlessButton).fixedSize().help("任务活动")
      Button { _ = store.setPetVisible(false) } label: { Image(systemName: "xmark") }
        .buttonStyle(.borderless).help("隐藏宠物")
    }
    .padding(.horizontal, 10).frame(height: 42)
    .background(.thinMaterial, in: Capsule())
  }

  private func submit() {
    guard !sending else { return }
    let value = prompt
    sending = true
    Task {
      if await store.sendPetPrompt(value) { prompt = "" }
      sending = false
    }
  }
}

private struct CodeyPetAnimation: View {
  let status: PetActivityStatus
  let reduceMotion: Bool
  var body: some View {
    TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 0.08)) { context in
      let phase = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
      let bob = sin(phase * (status == .running ? 6 : 2.5)) * (status == .running ? 5 : 2)
      ZStack {
        Capsule().fill(.black.opacity(0.12)).frame(width: 76, height: 12).offset(y: 57)
        RoundedRectangle(cornerRadius: 30)
          .fill(Color(nsColor: status.color).gradient)
          .frame(width: 104, height: 104)
          .overlay {
            HStack(spacing: 22) {
              Circle().fill(.white).frame(width: 13, height: 18)
              Circle().fill(.white).frame(width: 13, height: 18)
            }.offset(y: -7)
          }
          .overlay(alignment: .bottom) {
            Capsule().fill(.white.opacity(0.86)).frame(
              width: status == .blocked || status == .needsInput ? 32 : 42, height: 8)
              .padding(.bottom, 25)
          }
          .rotationEffect(.degrees(status == .ready ? sin(phase * 4) * 4 : 0))
          .offset(y: bob)
        Image(systemName: status == .running ? "gearshape.2.fill" : "chevron.left.forwardslash.chevron.right")
          .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
          .offset(y: 33 + bob)
      }
    }
  }
}

private struct CustomPetAnimation: View {
  let image: NSImage
  let row: Int
  let reduceMotion: Bool
  var body: some View {
    TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 0.12)) { context in
      frameView(at: context.date)
    }
  }

  @ViewBuilder private func frameView(at date: Date) -> some View {
    let frame = reduceMotion ? 0 : Int(date.timeIntervalSinceReferenceDate / 0.12) % 8
    if let frameImage = PetAtlas.frame(image: image, row: row, column: frame) {
      Image(nsImage: frameImage).resizable().interpolation(.none).scaledToFit()
    } else {
      EmptyView()
    }
  }
}
