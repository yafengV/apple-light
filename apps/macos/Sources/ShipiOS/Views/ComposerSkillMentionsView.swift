import SwiftUI

struct ComposerSkillMentionsView: View {
  @Binding var selection: SkillMentionSelection
  let accept: (PluginSkillReference) -> Void

  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { reader in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(selection.matches) { skill in
              Button { accept(skill) } label: {
                HStack(spacing: 10) {
                  Image(systemName: "wand.and.stars")
                  VStack(alignment: .leading, spacing: 2) {
                    Text(skill.title).appFont(.caption, weight: .medium)
                    Text("$\(skill.mention)").appFont(.caption2, design: .monospaced)
                      .foregroundStyle(.secondary)
                  }
                  Spacer()
                  Text(skill.pluginName).appFont(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }.padding(.horizontal, 9).frame(height: 42).contentShape(Rectangle())
                  .background(
                    selection.selected == skill ? Color.primary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
              }.buttonStyle(.plain)
                .accessibilityAddTraits(selection.selected == skill ? .isSelected : [])
                .onHover { if $0 { selection.highlight(skill) } }
                .id(skill.id)
            }
          }.padding(6)
        }.frame(height: min(CGFloat(selection.matches.count) * 44 + 10, 230))
          .onChange(of: selection.selected) { _, skill in
            if let skill { reader.scrollTo(skill.id) }
          }
      }
      Divider()
      HStack {
        Text("↑↓ 选择 · ↵ / Tab 确认")
        Spacer()
        Text("esc 关闭")
      }.appFont(size: 10).foregroundStyle(.secondary).padding(8)
    }.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
      .accessibilityLabel("技能选择")
  }
}
