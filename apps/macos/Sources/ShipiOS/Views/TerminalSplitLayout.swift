import SwiftUI

/// A draggable splitter that keeps two live terminal views mounted while resizing.
struct TerminalSplitLayout<Leading: View, Trailing: View>: View {
  let fraction: Double
  let onChange: (Double) -> Void
  let leading: Leading
  let trailing: Trailing

  init(fraction: Double, onChange: @escaping (Double) -> Void,
    @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
    self.fraction = fraction
    self.onChange = onChange
    self.leading = leading()
    self.trailing = trailing()
  }

  var body: some View {
    GeometryReader { geometry in
      let available = max(0, geometry.size.width - WorkspacePanelSizes.divider)
      let minimum = min(160, available / 2)
      let leftWidth = min(max(available * fraction, minimum), available - minimum)
      HStack(spacing: 0) {
        leading.frame(width: leftWidth)
        PanelResizeHandle(axis: .vertical, growsTowardLeading: false,
          value: leftWidth, bounds: minimum...(available - minimum),
          label: "调整拆分终端宽度",
          onResize: { width in
            guard available > 0 else { return }
            onChange(width / available)
          }, onEnd: {}, onReset: { onChange(0.5) })
          .frame(width: WorkspacePanelSizes.divider)
        trailing.frame(maxWidth: .infinity)
      }
    }
  }
}
