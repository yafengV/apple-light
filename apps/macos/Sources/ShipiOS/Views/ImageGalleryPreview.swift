import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A gallery scoped to the clicked attachment group, contained in its task window.
struct ImageGalleryPreview: View {
  let images: [ImagePreviewItem]
  let root: URL
  let close: () -> Void
  @State private var selectedID: String
  @State private var raster: CGImage?
  @State private var error: String?
  @State private var saveError: String?
  @State private var retry = UUID()
  @State private var zoom = ImagePreviewZoom(naturalSize: .zero, viewport: .zero)
  @FocusState private var focused: Control?
  private enum Control: Hashable { case close, previous, next, smaller, larger, save, retry }

  init(image: ImagePreviewItem, images: [ImagePreviewItem], root: URL, close: @escaping () -> Void) {
    self.images = images.contains(where: { $0.id == image.id }) ? images : [image]
    self.root = root
    self.close = close
    _selectedID = State(initialValue: image.id)
  }
  private var index: Int { images.firstIndex { $0.id == selectedID } ?? 0 }
  private var image: ImagePreviewItem { images[index] }
  private var controls: [Control] {
    [.close] + (raster == nil ? [] : [.save]) + (index > 0 ? [.previous] : [])
      + (index + 1 < images.count ? [.next] : []) + (error == nil ? [] : [.retry])
      + (raster != nil && zoom.percent > zoom.minimum + 0.001 ? [.smaller] : [])
      + (raster != nil && zoom.percent < 500 ? [.larger] : [])
  }

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        Color.black.opacity(0.9).onTapGesture(perform: close).accessibilityHidden(true)
        VStack(spacing: 16) {
          HStack(spacing: 12) {
            Spacer()
            button(.save, title: "保存图片", symbol: "arrow.down.to.line") { save() }
              .disabled(raster == nil)
            button(.close, title: "关闭图片预览", symbol: "xmark", action: close)
          }
          HStack(spacing: 12) {
            if index > 0 { button(.previous, title: "上一张图片", symbol: "chevron.left") { move(-1) } }
            viewport.frame(maxWidth: .infinity, maxHeight: .infinity)
            if index + 1 < images.count { button(.next, title: "下一张图片", symbol: "chevron.right") { move(1) } }
          }
          VStack(spacing: 10) {
            if images.count > 1 { Text("\(index + 1) / \(images.count)").appFont(.caption).foregroundStyle(.white.opacity(0.7)) }
            Text(image.name).appFont(size: 13).lineLimit(2).multilineTextAlignment(.center)
              .padding(.horizontal, 16).padding(.vertical, 8)
              .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            if let saveError { Text(saveError).appFont(.caption).foregroundStyle(.red) }
            HStack(spacing: 4) {
              button(.smaller, title: "缩小图片", symbol: "minus.magnifyingglass") { step(-1) }
                .disabled(raster == nil || zoom.percent <= zoom.minimum + 0.001)
              Text(raster == nil ? "—" : "\(Int(zoom.percent.rounded()))%")
                .monospacedDigit().frame(minWidth: 56).accessibilityLabel("图片缩放比例")
                .accessibilityValue(raster == nil ? "—" : "\(Int(zoom.percent.rounded()))%")
              button(.larger, title: "放大图片", symbol: "plus.magnifyingglass") { step(1) }
                .disabled(raster == nil || zoom.percent >= 500)
            }.padding(4).background(.white.opacity(0.12), in: Capsule())
              .help("⌘+ 放大，⌘− 缩小，⌘0 适应窗口；拖动或滚动查看放大后的图片")
          }.padding(.bottom, 12)
        }.padding(20).frame(width: geometry.size.width, height: geometry.size.height)
      }.foregroundStyle(.white).preferredColorScheme(.dark)
        .accessibilityElement(children: .contain).accessibilityAddTraits(.isModal)
        .accessibilityLabel("图片预览").accessibilityIdentifier("image-preview-overlay")
    }
    .background(ImagePreviewKeyboardBridge(onReady: { focused = .close }, action: handleKey)
      .frame(width: 0, height: 0))
    .task(id: "\(selectedID)-\(retry)") {
      raster = nil
      error = nil
      zoom.requestedPercent = nil
      let selected = image, directory = root
      do {
        let result = try await Task.detached(priority: .userInitiated) {
          // Decode bounded originals with their natural pixels and EXIF orientation.
          try selected.raster(root: directory)
        }.value
        guard !Task.isCancelled, selectedID == selected.id else { return }
        raster = result
      } catch {
        guard !Task.isCancelled, selectedID == selected.id else { return }
        self.error = error.localizedDescription
      }
    }
  }

  @ViewBuilder private var viewport: some View {
    if let raster {
      let selection = selectedID
      ImagePreviewCanvas(image: raster, requestedPercent: zoom.requestedPercent,
        onChange: { value in
          guard selectedID == selection, self.raster === raster else { return }
          zoom = value
        }, onDismiss: close)
        .accessibilityLabel(image.name).id(selectedID)
    } else if let error {
      VStack(spacing: 12) {
        Text("无法加载这张图片").appFont(.headline)
        Text(error).appFont(.caption).foregroundStyle(.white.opacity(0.7))
        Button("重试") { retry = UUID() }
          .buttonStyle(.plain).padding(10).background(.white.opacity(0.12), in: Capsule())
          .focusable().focused($focused, equals: .retry)
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    } else { ProgressView("正在加载图片…").frame(maxWidth: .infinity, maxHeight: .infinity) }
  }
  private func button(_ control: Control, title: String, symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: symbol).frame(width: 36, height: 36).contentShape(Circle()) }
      .buttonStyle(.plain).background(.white.opacity(0.1), in: Circle())
      .focusable().focused($focused, equals: control)
      .accessibilityLabel(title).help(title)
  }
  private func step(_ direction: Int) {
    guard raster != nil else { return }
    zoom.requestedPercent = zoom.step(direction)
  }
  private func move(_ direction: Int) {
    guard images.indices.contains(index + direction) else { return }
    selectedID = images[index + direction].id
    raster = nil
    error = nil
    saveError = nil
    zoom.requestedPercent = nil
    focused = .close
  }
  private func handleKey(_ key: ImagePreviewKeyboardBridge.Key) -> Bool {
    switch key {
    case .close: close()
    case .previous: guard index > 0 else { return false }; move(-1)
    case .next: guard index + 1 < images.count else { return false }; move(1)
    case .zoomIn: step(1)
    case .zoomOut: step(-1)
    case .fit: zoom.requestedPercent = nil
    case .tab(let backwards):
      let available = controls
      let current = focused.flatMap { available.firstIndex(of: $0) }
      let next = current.map { ($0 + (backwards ? available.count - 1 : 1)) % available.count }
      focused = available[next ?? (backwards ? available.count - 1 : 0)]
    case .activate:
      switch focused {
      case .close: close()
      case .previous: move(-1)
      case .next: move(1)
      case .smaller: step(-1)
      case .larger: step(1)
      case .save: if raster != nil { save() }
      case .retry: retry = UUID()
      case nil: return false
      }
    }
    return true
  }
  private func save() {
    guard let window = NSApp.keyWindow else { return }
    saveError = nil
    let selected = image, directory = root
    let panel = NSSavePanel()
    panel.nameFieldStringValue = selected.name
    panel.allowedContentTypes = [UTType(mimeType: selected.mimeType) ?? .png]
    panel.beginSheetModal(for: window) { response in
      guard response == .OK, let url = panel.url else { return }
      do { try selected.data(root: directory).write(to: url, options: .atomic) }
      catch { self.saveError = error.localizedDescription }
    }
  }
}
