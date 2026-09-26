import AppKit
import SwiftUI

struct CodexPlanDocumentView: View {
  let document: CodexPlanDocument
  let runID: String
  @Environment(\.openURL) private var openURL

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label(document.title, systemImage: "text.document")
          .appFont(.headline).lineLimit(1)
        Spacer()
        Button("复制计划", systemImage: "doc.on.doc") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(document.text, forType: .string)
        }
        .buttonStyle(.borderless)
      }
      .padding(.horizontal, 20).padding(.vertical, 12)
      Divider()
      ScrollView {
        MessageMarkdownView(source: document.text, runID: runID, partPrefix: "plan-document") {
          openURL($0)
        }
        .frame(maxWidth: 780, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(24)
      }
    }
  }
}
