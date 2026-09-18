import SwiftUI

struct ComposerPluginMentionsView: View {
  @Binding var selection: PluginMentionSelection
  let accept: (PluginInstallation) -> Void

  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { reader in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(selection.matches) { plugin in
              Button {
                accept(plugin)
              } label: {
                HStack(spacing: 10) {
                  Image(systemName: "shippingbox")
                  VStack(alignment: .leading, spacing: 2) {
                    Text(plugin.name).appFont(.caption, weight: .medium)
                    Text("@\(plugin.id)").appFont(.caption2, design: .monospaced)
                      .foregroundStyle(.secondary)
                  }
                  Spacer()
                  Text(plugin.components.labels.joined(separator: " · "))
                    .appFont(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }.padding(.horizontal, 9).frame(height: 42).contentShape(Rectangle())
                  .background(
                    selection.selected == plugin ? Color.primary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
              }.buttonStyle(.plain)
                .accessibilityAddTraits(selection.selected == plugin ? .isSelected : [])
                .onHover { if $0 { selection.highlight(plugin) } }
                .id(plugin.id)
            }
          }.padding(6)
        }.frame(height: min(CGFloat(selection.matches.count) * 44 + 10, 230))
          .onChange(of: selection.selected) { _, plugin in
            if let plugin { reader.scrollTo(plugin.id) }
          }
      }
      Divider()
      HStack {
        Text("↑↓ 选择 · ↵ / Tab 确认")
        Spacer()
        Text("esc 关闭")
      }.appFont(size: 10).foregroundStyle(.secondary).padding(8)
    }.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
      .accessibilityLabel("插件选择")
  }
}
