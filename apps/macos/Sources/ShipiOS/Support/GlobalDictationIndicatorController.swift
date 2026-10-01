import AppKit
import Observation
import SwiftUI

@MainActor final class GlobalDictationIndicatorController {
  static let windowSize = NSSize(width: 720, height: 84)
  static let bottomInset: CGFloat = 16

  private weak var store: WorkspaceStore?
  private let panel: GlobalDictationIndicatorPanel
  private var screenObserver: NSObjectProtocol?
  private var errorMessage: String?
  private var recoverableTranscript: String?
  private var observedErrorTarget: String?
  private var copiedTranscript = false
  private var lastState = GlobalDictationIndicatorState.hidden

  init(store: WorkspaceStore) {
    self.store = store
    panel = GlobalDictationIndicatorPanel(
      contentRect: NSRect(origin: .zero, size: Self.windowSize),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.title = "全局听写"
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.ignoresMouseEvents = true
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor [weak self] in self?.positionWindow() }
    }
    refresh()
    observeStore()
  }

  func showError(_ message: String, transcript: String? = nil) {
    if let target = store?.dictation.errorTarget, target.hasPrefix("global-dictation:") {
      observedErrorTarget = target
    }
    errorMessage = message
    recoverableTranscript = transcript?.isEmpty == false ? transcript : nil
    copiedTranscript = false
    refresh()
  }

  func clearError() {
    errorMessage = nil
    recoverableTranscript = nil
    copiedTranscript = false
    refresh()
  }

  func hide() { panel.orderOut(nil) }

  func refresh() {
    guard let store else { panel.orderOut(nil); return }
    if let target = store.dictation.errorTarget, target.hasPrefix("global-dictation:"),
      target != observedErrorTarget, let error = store.dictation.error {
      observedErrorTarget = target
      errorMessage = error
      recoverableTranscript = nil
      copiedTranscript = false
    }
    let hasHotkey = store.voicePreferences.globalHoldHotkey != nil
      || store.voicePreferences.globalToggleHotkey != nil
    let state = GlobalDictationIndicatorState.resolve(hasHotkey: hasHotkey,
      target: store.dictation.target, phase: store.dictation.phase,
      hasError: errorMessage != nil)
    guard state != .hidden else {
      lastState = state
      panel.orderOut(nil)
      return
    }
    panel.ignoresMouseEvents = state != .error
    panel.contentView = NSHostingView(rootView: GlobalDictationIndicatorView(
      state: state, dictation: store.dictation, error: errorMessage,
      canCopy: recoverableTranscript != nil,
      copied: copiedTranscript, onCopy: { [weak self] in self?.copyTranscript() },
      onDismiss: { [weak self] in self?.clearError() }))
    if !panel.isVisible || state == .initializing && lastState != .initializing {
      positionWindow()
    }
    if !panel.isVisible { panel.orderFrontRegardless() }
    lastState = state
  }

  private func observeStore() {
    guard let store else { return }
    withObservationTracking {
      _ = store.dictation.target
      _ = store.dictation.phase
      _ = store.dictation.errorTarget
      _ = store.dictation.error
      _ = store.voicePreferences
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.refresh()
        self?.observeStore()
      }
    }
  }

  private func positionWindow() {
    let pointer = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
      ?? NSScreen.main ?? NSScreen.screens.first else { return }
    let workArea = screen.visibleFrame
    let width = min(Self.windowSize.width, workArea.width)
    panel.setFrame(NSRect(x: workArea.midX - width / 2,
      y: workArea.minY + Self.bottomInset, width: width,
      height: Self.windowSize.height), display: false)
  }

  private func copyTranscript() {
    guard let recoverableTranscript else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(recoverableTranscript, forType: .string)
    copiedTranscript = true
    refresh()
  }

  deinit {
    if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    panel.close()
  }
}

private final class GlobalDictationIndicatorPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

private struct GlobalDictationIndicatorView: View {
  let state: GlobalDictationIndicatorState
  let dictation: SpeechDictation
  let error: String?
  let canCopy: Bool
  let copied: Bool
  let onCopy: () -> Void
  let onDismiss: () -> Void

  var body: some View {
    VStack {
      Spacer()
      Group {
        switch state {
        case .hidden: EmptyView()
        case .idle, .initializing:
          RoundedRectangle(cornerRadius: 4)
            .fill(.black.opacity(0.7))
            .frame(width: 40, height: 8)
            .accessibilityLabel(state == .idle ? "全局听写已就绪" : "正在准备全局听写")
        case .listening:
          GlobalDictationWaveformView(levels: dictation.audioLevels)
            .background(.black, in: Capsule())
            .accessibilityLabel("正在全局听写")
        case .transcribing:
          ProgressView().controlSize(.mini).tint(.white)
            .frame(width: 72, height: 30)
            .background(.black, in: Capsule())
            .accessibilityLabel("正在整理听写")
        case .error:
          HStack(spacing: 8) {
            Text(error ?? "听写失败")
              .lineLimit(1).truncationMode(.tail)
            if canCopy {
              Button(copied ? "已复制" : "复制") { onCopy() }
                .disabled(copied)
            }
            Button { onDismiss() } label: { Image(systemName: "xmark") }
              .accessibilityLabel("关闭听写错误")
          }
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.white)
          .buttonStyle(.plain)
          .padding(.horizontal, 10)
          .frame(maxWidth: 304, minHeight: 32)
          .background(.black, in: RoundedRectangle(cornerRadius: 16))
          .accessibilityElement(children: .contain)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.clear)
  }
}

struct GlobalDictationWaveformView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let levels: [Double]

  var body: some View {
    HStack(alignment: .center, spacing: 2) {
      ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
        Capsule().fill(.white)
          .frame(width: 2, height: max(2, 2 + level * 12))
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.06), value: levels)
    .frame(width: 72, height: 30)
  }
}
