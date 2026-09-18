import SwiftUI

struct RunInspectorView: View {
  @Bindable var store: WorkspaceStore
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("任务详情").appFont(.headline)
        Spacer()
        Button {
          store.showingInspector = false
        } label: {
          Image(systemName: "xmark")
        }.buttonStyle(.plain).help("关闭详情")
      }.padding(16)
      Picker("详情", selection: $store.inspectorTab) {
        Text("诊断").tag("diagnostics")
        Text("日志").tag("logs")
        Text("产物").tag("artifacts")
      }.pickerStyle(.segmented).padding(.horizontal, 14).padding(.bottom, 14)
      Divider()
      if let run = store.selectedRun {
        HStack {
          StatusLabel(run: run)
          Spacer()
          Text(run.date, style: .time).foregroundStyle(.secondary)
        }.appFont(.caption).padding(14)
        if store.inspectorTab == "logs" {
          Picker("日志文件", selection: $store.logName) {
            Text("标准输出").tag("stdout.log")
            Text("标准错误").tag("stderr.log")
          }.labelsHidden().padding(.horizontal, 14)
          ScrollView([.horizontal, .vertical]) {
            Text(store.logText.isEmpty ? (run.isActive ? "执行结束后显示日志。" : "日志为空。") : store.logText)
              .appFont(size: 11, design: .monospaced).textSelection(.enabled).padding(14)
          }.defaultScrollAnchor(.topLeading).frame(minHeight: 0, maxHeight: .infinity)
        } else {
          ScrollView {
            VStack(alignment: .leading, spacing: 18) {
              if store.inspectorTab == "diagnostics" {
                let diagnostics = run.result?["command"]["diagnostics"].items ?? []
                if diagnostics.isEmpty {
                  Label(
                    run.isActive ? "等待执行结果" : "没有编译器诊断",
                    systemImage: run.isActive ? "clock" : "checkmark.circle"
                  ).foregroundStyle(.secondary)
                }
                ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, item in
                  VStack(alignment: .leading, spacing: 8) {
                    Label(
                      item["severity"].text == "error" ? "错误" : "警告",
                      systemImage: "exclamationmark.circle"
                    ).foregroundStyle(.orange)
                    Text(item["message"].text ?? "").textSelection(.enabled)
                    if let file = item["file"].text {
                      Text(file + (item["line"].int.map { ":\($0)" } ?? "")).appFont(.caption)
                        .foregroundStyle(.secondary).textSelection(.enabled)
                    }
                  }
                  Divider()
                }
                if let message = run.result?["message"].text {
                  Text(message).textSelection(.enabled)
                }
              } else {
                LabeledContent("类型", value: run.kind == "doctor" ? "环境诊断" : "构建")
                if let code = run.result?["command"]["exitCode"].int {
                  LabeledContent("退出码", value: String(code))
                }
                if let time = run.result?["command"]["durationMs"].int {
                  LabeledContent("耗时", value: String(format: "%.1f 秒", Double(time) / 1000))
                }
                if let directory = run.result?["artifactDirectory"].text {
                  Text(directory).appFont(.caption, design: .monospaced).foregroundStyle(
                    .secondary
                  ).textSelection(.enabled)
                  Button("在 Finder 中显示", systemImage: "folder") { store.revealArtifacts() }
                }
                Button("导出 JSON 报告…", systemImage: "square.and.arrow.up") {
                  Task { await store.exportReport() }
                }.disabled(run.isActive || !store.connected)
                Divider()
                Text("本次结果覆盖环境检查或编译，不包含 iOS 交互测试和上架验证。").appFont(.caption).foregroundStyle(
                  .secondary)
              }
            }.appFont(.callout).padding(16).frame(maxWidth: .infinity, alignment: .leading)
          }.frame(minHeight: 0, maxHeight: .infinity)
        }
      } else {
        ContentUnavailableView(
          "尚未选择任务", systemImage: "sidebar.right", description: Text("执行任务后，在这里查看诊断、日志和产物。"))
      }
    }
  }
}
