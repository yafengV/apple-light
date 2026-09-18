import SwiftUI

struct MCPServerEditorView: View {
  @Bindable var store: WorkspaceStore
  @State var server: MCPServerConfiguration
  @State private var confirmingRemoval = false
  private var existing: Bool { store.mcpServers.contains { $0.id == server.id } }
  private var editState: MCPServerEditState { store.mcpServerEditState(server) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Button { store.mcpServerEditor = nil; store.mcpServersError = nil } label: {
          Label("返回", systemImage: "chevron.left")
        }
        Text(existing ? "更新 \(server.name) MCP" : "连接自定义 MCP")
          .appFont(.title2, weight: .semibold)
        Spacer()
        if !existing {
          Link("文档", destination: URL(string: "https://developers.openai.com/codex/mcp/")!)
            .accessibilityLabel("打开 MCP 文档")
        }
        if existing {
          Button("卸载", role: .destructive) { confirmingRemoval = true }
        }
      }.padding(.horizontal, 24).padding(.top, 32)
      Form {
        Section {
          if existing {
            LabeledContent("名称", value: server.name)
            LabeledContent("类型", value: server.transport.title)
            Text("若要更换 MCP 服务器类型，请先卸载原配置。")
              .foregroundStyle(.secondary)
          } else {
            TextField("名称", text: $server.name, prompt: Text("MCP 服务器名称"))
            Picker("类型", selection: $server.transport) {
              ForEach(MCPTransport.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
          }
        }
        if server.transport == .stdio {
          Section("启动") {
            TextField("启动命令", text: $server.command, prompt: Text("例如：/usr/local/bin/server"))
            MCPStringListEditor(title: "参数", addLabel: "添加参数", values: $server.arguments)
            TextField("工作目录", text: $server.workingDirectory, prompt: Text("~/code"))
          }
          Section("环境") {
            MCPKeyValueEditor(title: "环境变量", addLabel: "添加环境变量", entries: $server.environment)
            MCPStringListEditor(title: "环境变量透传", addLabel: "添加变量", values: $server.environmentPassthrough)
          }
        } else {
          Section("连接") {
            TextField("URL", text: $server.url, prompt: Text("https://mcp.example.com/mcp"))
            TextField("Bearer token 环境变量", text: $server.bearerTokenEnvironmentVariable,
              prompt: Text("MCP_BEARER_TOKEN"))
          }
          Section("请求头") {
            MCPKeyValueEditor(title: "请求头", addLabel: "添加请求头", entries: $server.headers)
            MCPKeyValueEditor(title: "从环境变量读取请求头", addLabel: "添加变量", entries: $server.environmentHeaders)
          }
        }
        if let error = store.mcpServersError ?? (server != store.mcpServerEditor ? editState.validationMessage : nil) {
          Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        Section {
          Text("保存后可在列表连接服务器并查看可用工具。修改配置会断开已有连接。")
            .foregroundStyle(.secondary)
          HStack {
            Spacer()
            Button("保存") { _ = store.saveMCPServer(server) }
              .buttonStyle(.borderedProminent)
              .disabled(!store.mcpServersLoaded || !editState.canSave)
          }
        }
      }.formStyle(.grouped).appSurface()
    }
    .onChange(of: server) { _, _ in store.mcpServersError = nil }
    .alert("卸载 MCP 服务器？", isPresented: $confirmingRemoval) {
      Button("取消", role: .cancel) {}
      Button("卸载", role: .destructive) { _ = store.removeMCPServer(server.id) }
    } message: { Text("将从 ShipiOS 中移除这个服务器的配置。") }
  }
}

private struct MCPStringListEditor: View {
  let title: String
  let addLabel: String
  @Binding var values: [String]
  @State private var rowIDs: [UUID]

  init(title: String, addLabel: String, values: Binding<[String]>) {
    self.title = title
    self.addLabel = addLabel
    _values = values
    _rowIDs = State(initialValue: values.wrappedValue.map { _ in UUID() })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).appFont(.headline)
      ForEach(rowIDs, id: \.self) { id in
        HStack {
          TextField(title, text: Binding(
            get: {
              guard let index = rowIDs.firstIndex(of: id), values.indices.contains(index) else { return "" }
              return values[index]
            },
            set: { value in
              guard let index = rowIDs.firstIndex(of: id), values.indices.contains(index) else { return }
              values[index] = value
            })).textFieldStyle(.roundedBorder)
          Button {
            guard let index = rowIDs.firstIndex(of: id), values.indices.contains(index) else { return }
            values.remove(at: index)
            rowIDs.remove(at: index)
          } label: { Image(systemName: "minus.circle") }
            .accessibilityLabel("移除\(title) \((rowIDs.firstIndex(of: id) ?? 0) + 1)")
        }
      }
      Button(addLabel) { values.append(""); rowIDs.append(UUID()) }.disabled(values.count >= 100)
    }.padding(.vertical, 4)
  }
}

private struct MCPKeyValueEditor: View {
  let title: String
  let addLabel: String
  @Binding var entries: [MCPKeyValue]
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).appFont(.headline)
      ForEach($entries) { $entry in
        HStack {
          TextField("名称", text: $entry.key).accessibilityLabel("\(title)名称")
          TextField("值", text: $entry.value).accessibilityLabel("\(title)值")
          Button { entries.removeAll { $0.id == entry.id } } label: { Image(systemName: "minus.circle") }
            .accessibilityLabel("移除\(title)：\(entry.key)")
        }.textFieldStyle(.roundedBorder)
      }
      Button(addLabel) { entries.append(MCPKeyValue()) }.disabled(entries.count >= 100)
    }.padding(.vertical, 4)
  }
}
