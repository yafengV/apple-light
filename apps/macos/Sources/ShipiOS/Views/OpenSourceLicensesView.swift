import SwiftUI

struct OpenSourceLicensesView: View {
  let directory: URL
  @State private var licenses: [OpenSourceLicense] = []
  @State private var selectedID: String?
  @State private var loadError: String?

  init(directory: URL? = nil) {
    self.directory = directory ?? (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
      .appendingPathComponent("Licenses", isDirectory: true)
  }

  var body: some View {
    SettingsScrollPage(title: "开源许可") {
      EmptyView()
    } controls: {
      EmptyView()
    } content: {
      if let loadError {
        ContentUnavailableView("无法读取开源许可", systemImage: "doc.text", description: Text(loadError))
        Button("重试") { reload() }
      } else if licenses.isEmpty {
        ContentUnavailableView("没有捆绑的许可文件", systemImage: "doc.text")
      } else {
        Text("所捆绑依赖的第三方声明")
          .foregroundStyle(.secondary)
        HStack(alignment: .top, spacing: 20) {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(licenses) { license in
              Button {
                selectedID = license.id
              } label: {
                Text(license.title).lineLimit(2)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.horizontal, 10).padding(.vertical, 8)
                  .background(selectedID == license.id ? Color.accentColor.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
              }
              .buttonStyle(.plain)
              .accessibilityAddTraits(selectedID == license.id ? .isSelected : [])
            }
          }.frame(width: 210)
          Divider()
          if let license = licenses.first(where: { $0.id == selectedID }) {
            VStack(alignment: .leading, spacing: 12) {
              Text(license.title).appFont(size: 16, weight: .semibold)
              Text(license.text).font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityIdentifier("open-source-license-content")
          }
        }
      }
    }
    .task { reload() }
  }

  private func reload() {
    do {
      licenses = try OpenSourceLicenses.load(from: directory)
      if !licenses.contains(where: { $0.id == selectedID }) { selectedID = licenses.first?.id }
      loadError = nil
    } catch {
      licenses = []
      selectedID = nil
      loadError = error.localizedDescription
    }
  }
}
