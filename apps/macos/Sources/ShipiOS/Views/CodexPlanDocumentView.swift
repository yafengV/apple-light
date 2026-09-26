import AppKit
import SwiftUI

struct CodexPlanDocumentView: View {
  @Environment(\.messageBrowserRoute) private var openInApp
  let store: WorkspaceStore
  let run: AgentRun
  let document: CodexPlanDocument

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
        MessageMarkdownView(source: document.text, runID: run.id, partPrefix: "plan-document",
          linkActions: MessageLinkActions(
            activate: { url, click in
              store.openMessageLink(url, project: store.workspaceRoot(for: run), ownerRunID: run.id,
                click: click, openInApp: openInApp)
            },
            perform: { url, action in
              store.performMessageLinkAction(action, url: url, ownerRunID: run.id, openInApp: openInApp)
            }
          )) { url in
          store.openMessageLink(url, project: store.workspaceRoot(for: run), ownerRunID: run.id,
            click: WebLinkClick(event: NSApp.currentEvent), openInApp: openInApp)
        }
        .frame(maxWidth: 780, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(24)
      }
    }
  }
}
