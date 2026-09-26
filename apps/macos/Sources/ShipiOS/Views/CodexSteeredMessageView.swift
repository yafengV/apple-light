import SwiftUI

struct CodexSteeredMessageView: View {
  let store: WorkspaceStore
  let runID: String
  let message: QueuedMessage

  var body: some View {
    VStack(alignment: .trailing, spacing: 7) {
      if !message.files.isEmpty {
        FileAttachmentsView(store: store, files: message.files)
      }
      if !message.images.isEmpty {
        ImageAttachmentsView(store: store, images: message.images)
      }
      if !message.text.isEmpty {
        ConversationSearchText(message.text,
          id: .init(run: runID, part: "steer." + message.id.uuidString))
          .appFont(size: 14).textSelection(.enabled)
          .padding(.horizontal, 17).padding(.vertical, 12)
          .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
      }
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
  }
}
