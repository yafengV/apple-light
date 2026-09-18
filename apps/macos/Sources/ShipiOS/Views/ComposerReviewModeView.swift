import SwiftUI

struct ComposerReviewModeView: View {
  @Bindable var store: WorkspaceStore
  @State private var query = ""
  @FocusState private var searchFocused: Bool

  private var matches: [GitReviewChoice] {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else { return store.reviewModeBranches }
    return store.reviewModeBranches.filter {
      $0.title.localizedCaseInsensitiveContains(term)
        || $0.id.localizedCaseInsensitiveContains(term)
    }
  }

  private var offersExactReference: Bool {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return !term.isEmpty
      && !store.reviewModeBranches.contains {
        $0.title.caseInsensitiveCompare(term) == .orderedSame
          || $0.id.caseInsensitiveCompare(term) == .orderedSame
      }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 3) {
          Text("代码审查").appFont(.headline)
          Text("审查未提交的更改或与分支比较")
            .appFont(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          store.dismissCodeReviewMode()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.plain).help("关闭代码审查选项")
        .accessibilityLabel("关闭代码审查选项")
      }

      Button {
        Task { await store.startCodeReview(.uncommitted) }
      } label: {
        Label("审查未提交的更改", systemImage: "arrow.triangle.branch")
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.plain).padding(.vertical, 5)
      .disabled(store.reviewModeStarting)

      Divider()
      Text("针对基础分支进行审查")
        .appFont(.caption, weight: .semibold).foregroundStyle(.secondary)
      TextField("搜索或输入 Git 引用", text: $query)
        .textFieldStyle(.roundedBorder).focused($searchFocused)
        .disabled(store.reviewModeStarting)

      if store.reviewModeLoading {
        ProgressView("正在加载分支…").controlSize(.small).appFont(.caption)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(matches) { branch in
              branchButton(branch.title, reference: branch.id)
            }
            if offersExactReference {
              branchButton(
                "使用 \(query.trimmingCharacters(in: .whitespacesAndNewlines))",
                reference: query.trimmingCharacters(in: .whitespacesAndNewlines))
            }
          }
        }.frame(maxHeight: 150)
      }

      if let error = store.reviewModeError {
        HStack(alignment: .top) {
          Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
          Text(error).textSelection(.enabled)
          Spacer()
          if error.hasPrefix("无法加载分支") {
            Button("重试") { Task { await store.loadCodeReviewBranches() } }
          }
        }.appFont(.caption)
      }
      if store.reviewModeStarting {
        ProgressView("正在启动代码审查…").controlSize(.small).appFont(.caption)
      }
    }
    .padding(14)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.12)))
    .shadow(color: .black.opacity(0.1), radius: 14, y: 6)
    .onAppear { searchFocused = true }
    .onExitCommand { store.dismissCodeReviewMode() }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("代码审查选项")
  }

  private func branchButton(_ title: String, reference: String) -> some View {
    Button {
      Task { await store.startCodeReview(.branch(reference)) }
    } label: {
      HStack {
        Image(systemName: "arrow.triangle.branch")
        Text(title).lineLimit(1)
        Spacer()
      }.contentShape(Rectangle())
    }
    .buttonStyle(.plain).padding(.vertical, 5)
    .disabled(store.reviewModeStarting)
  }
}
