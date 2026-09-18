import SwiftUI

/// Command, task and file search share a current-window surface and focus boundary.
struct SearchDialog<Content: View>: View {
  let identifier: String
  let cancel: () -> Void
  @ViewBuilder let content: () -> Content

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color.black.opacity(0.3).contentShape(Rectangle())
          .onTapGesture(perform: cancel).accessibilityHidden(true)
        content()
          .frame(width: min(640, geometry.size.width * 0.92), height: min(430, geometry.size.height * 0.85))
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
          .clipShape(RoundedRectangle(cornerRadius: 16))
          .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
          .accessibilityElement(children: .contain).accessibilityAddTraits(.isModal)
          .accessibilityIdentifier(identifier)
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

private struct SearchDialogActiveKey: FocusedValueKey { typealias Value = Bool }
extension FocusedValues {
  var searchDialogActive: Bool? {
    get { self[SearchDialogActiveKey.self] }
    set { self[SearchDialogActiveKey.self] = newValue }
  }
}
