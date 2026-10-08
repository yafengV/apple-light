import AppKit
import SwiftUI

struct VoiceRecordingSettingsRow: View {
  @Bindable var store: WorkspaceStore
  let recording: VoiceRecording
  let download: () -> Void

  var body: some View {
    let text = recording.text.isEmpty ? recordingStatus(recording.status) : recording.text
    let timestamp = recording.createdAt.formatted(date: .abbreviated, time: .shortened)
    return SettingsLabeledRow {
      VStack(alignment: .leading, spacing: 2) {
        Text(text).appFont(size: 13)
          .settingsTextLineHeight(text: text, fontSize: 13, lineHeight: SettingsRowTypography.labelLineHeight)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
        Text(timestamp).appFont(size: 12).foregroundStyle(.secondary)
          .settingsTextLineHeight(text: timestamp, fontSize: 12, lineHeight: SettingsRowTypography.descriptionLineHeight)
      }
    } control: {
      HStack(spacing: 8) {
        if !recording.text.isEmpty {
          Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(recording.text, forType: .string)
          } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.plain)
            .disabled(store.voiceRecordingHistory.retryingID != nil)
            .accessibilityLabel("复制听写文本")
        } else if recording.sizeBytes > 0 && recording.status != .recording {
          if store.voiceRecordingHistory.retryingID == recording.id {
            ProgressView().controlSize(.small).accessibilityLabel("正在重试转写")
          } else {
            Button("重试") {
              Task {
                await store.voiceRecordingHistory.retry(recording.id,
                  languageIdentifier: store.voicePreferences.dictationLocaleIdentifier,
                  dictionary: store.voicePreferences.dictationDictionary)
              }
            }
            .disabled(store.voiceRecordingHistory.retryingID != nil)
            .accessibilityLabel("重试转写")
          }
        }
        Menu {
          if recording.sizeBytes > 0 {
            Button("下载录音") { download() }
          }
          Button("删除录音", role: .destructive) {
            do { try store.voiceRecordingHistory.delete(recording.id) }
            catch { store.voiceRecordingHistory.report(error) }
          }
            .disabled(recording.status == .recording)
        } label: { Image(systemName: "ellipsis") }
          .menuStyle(.borderlessButton)
          .frame(width: 24)
          .disabled(store.voiceRecordingHistory.retryingID != nil)
          .accessibilityLabel("录音操作")
      }
    }
    .padding(.horizontal, 16).padding(.vertical, 8)
  }

  private func recordingStatus(_ status: VoiceRecording.Status) -> String {
    switch status {
    case .recording: "正在录音"
    case .saved: "录音已保存"
    case .cancelled: "录音已取消"
    case .interrupted: "录音已中断"
    }
  }

}
