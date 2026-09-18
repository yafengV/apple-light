import SwiftUI

struct BrowserDownloadList: View {
  @Bindable var store: WorkspaceStore
  var compact = false

  var body: some View {
    if store.browserDownloads.isEmpty {
      ContentUnavailableView("暂无下载", systemImage: "arrow.down.circle")
        .frame(maxWidth: .infinity, minHeight: compact ? 90 : 140)
    } else {
      VStack(spacing: 0) {
        ForEach(store.browserDownloads) { record in
          BrowserDownloadRow(store: store, record: record, compact: compact)
          if record.id != store.browserDownloads.last?.id { Divider() }
        }
      }
    }
  }
}

private struct BrowserDownloadRow: View {
  @Bindable var store: WorkspaceStore
  let record: BrowserDownloadRecord
  let compact: Bool

  private var active: Bool {
    record.status == .preparing || record.status == .downloading
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: icon)
        .foregroundStyle(record.status == .failed ? Color.red : active ? Color.accentColor : Color.secondary)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 4) {
        Text(record.filename).lineLimit(1).textSelection(.enabled)
        if active {
          ProgressView(value: store.browserDownloadProgress[record.id] ?? 0)
            .progressViewStyle(.linear)
        }
        HStack(spacing: 6) {
          Text(record.status.title)
          if let byteCount = record.byteCount {
            Text(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
          }
          if !compact { Text(record.createdAt.formatted(date: .abbreviated, time: .shortened)) }
        }.appFont(size: 10).foregroundStyle(.secondary)
        if let message = record.message {
          Text(message).appFont(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
        if !compact, let path = record.destinationPath {
          Text(path).appFont(size: 10, design: .monospaced)
            .foregroundStyle(.tertiary).lineLimit(1).textSelection(.enabled)
        }
      }
      Spacer(minLength: 4)
      if active {
        Button("取消") { store.cancelBrowserDownload(record.id) }
          .controlSize(.small)
      } else if record.status == .finished {
        Button("打开") { store.openBrowserDownload(record) }.controlSize(.small)
        Button { store.revealBrowserDownload(record) } label: {
          Image(systemName: "folder")
        }.buttonStyle(.plain).help("在 Finder 中显示").accessibilityLabel("在 Finder 中显示")
      } else {
        Button { store.removeBrowserDownload(record.id) } label: {
          Image(systemName: "xmark")
        }.buttonStyle(.plain).help("移除下载记录").accessibilityLabel("移除下载记录")
      }
    }.padding(compact ? 8 : 10)
  }

  private var icon: String {
    switch record.status {
    case .preparing, .downloading: "arrow.down.circle"
    case .finished: "checkmark.circle.fill"
    case .failed: "exclamationmark.circle.fill"
    case .cancelled: "xmark.circle"
    }
  }
}
