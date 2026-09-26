import SwiftUI

struct CodexReasoningView: View {
  let sections: [String]
  @State private var expanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
          if !section.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(section).appFont(.callout).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }.padding(.top, 8)
    } label: {
      Label("思考摘要", systemImage: "brain.head.profile")
        .appFont(.caption).foregroundStyle(.secondary)
    }
    .padding(12)
    .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.06)))
  }
}
