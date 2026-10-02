import SwiftUI

struct TaskPullRequestCodeFileJumpView: View {
  let paths: [String]
  let select: (String) -> Void
  @State private var showing = false
  @State private var query = ""
  @State private var selected = 0
  @FocusState private var searchFocused: Bool
  private var matches: [GitHubPRCodeFileJump.Match] {
    GitHubPRCodeFileJump.matches(paths: paths, query: query)
  }

  var body: some View {
    Button { showing = true } label: { Image(systemName: "doc.text.magnifyingglass") }
      .buttonStyle(.plain).help("跳转到文件").accessibilityLabel("跳转到文件")
      .accessibilityIdentifier("pull-request-code-jump-to-file")
      .disabled(paths.isEmpty)
      .popover(isPresented: $showing, arrowEdge: .bottom) {
        VStack(spacing: 0) {
          TextField("跳转到文件", text: $query)
            .textFieldStyle(.plain).focused($searchFocused)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .onSubmit { chooseSelected() }
            .onKeyPress(.downArrow) {
              selected = min(max(0, matches.count - 1), selected + 1)
              return .handled
            }
            .onKeyPress(.upArrow) {
              selected = max(0, selected - 1)
              return .handled
            }
          Divider()
          if matches.isEmpty {
            Text("没有匹配的文件").foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, minHeight: 70)
          } else {
            ScrollViewReader { proxy in
              ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                  ForEach(Array(matches.enumerated()), id: \.element.id) { index, item in
                    Button { choose(item.path) } label: {
                      HStack(spacing: 8) {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        Text(item.fileName).lineLimit(1)
                        if !item.parentPath.isEmpty {
                          Text(item.parentPath).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                      }.padding(.horizontal, 10).frame(height: 30)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(selected == index ? Color.accentColor.opacity(0.14) : .clear,
                          in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).focusable(false).id(item.path)
                      .accessibilityLabel(item.path)
                      .onHover { hovered in if hovered { selected = index } }
                  }
                }.padding(5)
              }
              .onChange(of: selected) { _, index in
                if matches.indices.contains(index) { proxy.scrollTo(matches[index].path, anchor: nil) }
              }
            }
          }
        }
        .appFont(size: 13)
        .frame(width: 360, height: min(330, CGFloat(max(2, matches.count)) * 32 + 49))
        .onAppear { query = ""; selected = 0; searchFocused = true }
        .onChange(of: query) { _, _ in selected = 0 }
        .onExitCommand { showing = false }
      }
  }

  private func chooseSelected() {
    guard matches.indices.contains(selected) else { return }
    choose(matches[selected].path)
  }

  private func choose(_ path: String) {
    select(path)
    showing = false
  }
}
