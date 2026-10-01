import AppKit
import SwiftUI

struct AppshotMenuButton: View {
  let store: WorkspaceStore
  let draftKey: String
  let imageCount: Int
  @State private var target: AppshotTarget?

  static func title(for applicationName: String?) -> String {
    guard let name = applicationName?.trimmingCharacters(in: .whitespacesAndNewlines),
      !name.isEmpty else { return "截取应用窗口…" }
    return "附加 \(String(name.prefix(80)))"
  }

  static func isEnabled(hasTarget: Bool, imageCount: Int) -> Bool {
    hasTarget && imageCount < ImageAttachmentStorage.maxCount
  }

  var body: some View {
    Button {
      let selected = target
      Task {
        await store.captureAppshot(draft: draftKey) {
          try await store.appshotCapture.capture(target: selected)
        }
      }
    } label: {
      Label {
        Text(Self.title(for: target?.name))
      } icon: {
        if let icon = target?.icon {
          Image(nsImage: icon).resizable().frame(width: 16, height: 16)
        } else {
          Image(systemName: "camera.viewfinder")
        }
      }
    }
    .disabled(!Self.isEnabled(hasTarget: target != nil, imageCount: imageCount))
    .onAppear { target = store.appshotCapture.availableTarget() }
  }
}
