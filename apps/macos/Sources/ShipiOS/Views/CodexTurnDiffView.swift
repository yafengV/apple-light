import AppKit
import SwiftUI

struct CodexTurnDiffView: View {
  let diff: CodexTurnDiff
  let root: URL
  var onReview: (() -> Bool)? = nil
  @State private var expanded = false
  @State private var copied = false
  @State private var showingFullDiff = false
  @State private var files: [CodexTurnDiffFile] = []
  @State private var selectedFileID: Int? = 0
  @State private var loadError: String?
  @State private var showingAllFiles = false
  @Environment(\.appAppearance) private var appearance

  private var additions: Int { files.reduce(0) { $0 + ReviewDiff($1.patch).additions } }
  private var deletions: Int { files.reduce(0) { $0 + ReviewDiff($1.patch).deletions } }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "plus.app").foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 3) {
          Text("已编辑 \(diff.changedFileCount) 个文件").appFont(.callout, weight: .medium)
          if !files.isEmpty {
            HStack(spacing: 6) {
              Text("+\(additions)").foregroundStyle(appearance.diffAddedColor)
              Text("-\(deletions)").foregroundStyle(appearance.diffRemovedColor)
            }.appFont(.caption, design: .monospaced)
          }
        }
        Spacer(minLength: 8)
        Button("查看变更") {
          if onReview?() != true { openFullDiff() }
        }.controlSize(.small)
          .accessibilityLabel("查看本轮代码变更")
      }
      if let loadError {
        Text(loadError).foregroundStyle(.red).appFont(.caption)
      }
      if !files.isEmpty {
        Divider()
        ForEach(showingAllFiles ? files : Array(files.prefix(3))) { file in
          HStack(spacing: 8) {
            Text(file.path).lineLimit(1).truncationMode(.middle).help(file.path)
            Spacer(minLength: 8)
            Text("+\(ReviewDiff(file.patch).additions)").foregroundStyle(appearance.diffAddedColor)
            Text("-\(ReviewDiff(file.patch).deletions)").foregroundStyle(appearance.diffRemovedColor)
          }.appFont(.caption)
        }
        if files.count > 3 {
          Button(showingAllFiles ? "收起文件列表" : "再显示 \(files.count - 3) 个文件") {
            showingAllFiles.toggle()
          }.buttonStyle(.plain).appFont(.caption).foregroundStyle(.secondary)
        }
      }
      DisclosureGroup(isExpanded: $expanded) {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            if diff.truncated {
              Text("下方显示前 262,144 个字符。")
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(diff.truncated ? "查看完整差异" : "按文件查看") { openFullDiff() }
              .controlSize(.small)
            Button(copied ? "已复制" : "复制完整差异") { copyFullDiff() }
              .controlSize(.small)
          }.appFont(.caption)
          if let loadError {
            Text(loadError).foregroundStyle(.red).appFont(.caption)
          }
          ScrollView {
            Text(diff.unifiedDiff).appFont(.caption, design: .monospaced)
              .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
          }.frame(maxHeight: 320)
        }.padding(.top, 8)
      } label: {
        Text("原始差异").appFont(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.06)))
    .task(id: diff) {
      let snapshot = diff, dataRoot = root
      do {
        let source = try await Task.detached { try CodexTurnDiffStorage.load(snapshot, root: dataRoot) }.value
        guard !Task.isCancelled else { return }
        files = CodexTurnDiffFiles.parse(source)
        loadError = nil
      } catch {
        guard !Task.isCancelled else { return }
        files = []; loadError = error.localizedDescription
      }
    }
    .sheet(isPresented: $showingFullDiff) {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("本轮完整代码差异").font(.headline)
          Spacer()
          Button("完成") { dismissFullDiff() }
        }
        HStack(spacing: 0) {
          List(files, selection: $selectedFileID) { file in
            Text(file.path).lineLimit(2).tag(file.id)
          }.listStyle(.sidebar).frame(width: 240)
          Divider()
          VStack(alignment: .leading, spacing: 8) {
            if let file = files.first(where: { $0.id == selectedFileID }) {
              HStack {
                Text(file.path).appFont(.callout, weight: .semibold)
                  .lineLimit(1).help(file.path)
                Spacer()
                Button("复制此文件差异") {
                  NSPasteboard.general.clearContents()
                  NSPasteboard.general.setString(file.patch, forType: .string)
                }.controlSize(.small)
              }
              ScrollView {
                Text(file.patch).appFont(.caption, design: .monospaced)
                  .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
      }.padding(20).frame(minWidth: 900, minHeight: 520)
    }
    .onChange(of: diff) { _, _ in
      copied = false
      loadError = nil
      if showingFullDiff {
        let selectedPath = files.first { $0.id == selectedFileID }?.path
        openFullDiff()
        if let selectedPath, let matching = files.first(where: { $0.path == selectedPath }) {
          selectedFileID = matching.id
        }
      }
    }
    .onChange(of: showingFullDiff) { _, visible in
      if !visible { selectedFileID = 0 }
    }
  }

  private func openFullDiff() {
    do {
      let source = try CodexTurnDiffStorage.load(diff, root: root)
      files = CodexTurnDiffFiles.parse(source)
      selectedFileID = 0
      loadError = nil
      showingFullDiff = true
    } catch {
      if showingFullDiff { dismissFullDiff() }
      loadError = error.localizedDescription
    }
  }

  private func dismissFullDiff() {
    showingFullDiff = false
    selectedFileID = 0
  }

  private func copyFullDiff() {
    do {
      let source = try CodexTurnDiffStorage.load(diff, root: root)
      NSPasteboard.general.clearContents()
      guard NSPasteboard.general.setString(source, forType: .string) else {
        throw AgentFailure(message: "无法复制代码差异。")
      }
      copied = true
      loadError = nil
    } catch {
      loadError = error.localizedDescription
    }
  }
}
