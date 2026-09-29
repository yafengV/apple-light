import SwiftUI
import WebKit

/// A small offline code surface. It shares the application's verified tokenizer;
/// its WebKit document implements browser text selection and CSS Lab diff colors.
struct AppearanceCodePreview: View {
  let appearance: AppearancePreferences
  @Environment(\.isEnabled) private var enabled
  @State private var syntax = CodeSyntaxState()
  private struct Request: Hashable { let identity: CodeSyntaxIdentity; let enabled: Bool }
  private var input: CodeSyntaxInput { .init(path: AppearanceDiffPreview.path, diff: AppearanceDiffPreview.diff, themes: appearance.codeThemes) }
  var body: some View {
    AppearanceCodeSurface(appearance: appearance, syntax: syntax)
      .frame(height: appearance.codeSize * 1.8 * 5 + 8)
      .clipShape(RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(appearance.resolvedColors["border"].color, lineWidth: 1))
      .accessibilityLabel("主题差异预览")
      .task(id: Request(identity: input.identity, enabled: enabled)) {
        guard enabled else { return }; await syntax.load(input)
      }
      .onDisappear { syntax.cancel() }
  }
}

struct AppearanceCodeSurface: NSViewRepresentable {
  let appearance: AppearancePreferences
  let syntax: CodeSyntaxState
  @Environment(\.isEnabled) private var enabled
  @Environment(\.colorScheme) private var scheme
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> WebView {
    let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
    let web = WebView(frame: .zero, configuration: configuration)
    web.navigationDelegate = context.coordinator; web.setValue(false, forKey: "drawsBackground")
    web.setAccessibilityIdentifier("appearance-code-preview")
    web.loadHTMLString(Self.document, baseURL: nil)
    return web
  }
  func updateNSView(_ web: WebView, context: Context) {
    web.available = enabled
    if !enabled, let responder = web.window?.firstResponder as? NSView, responder === web || responder.isDescendant(of: web) {
      DispatchQueue.main.async { [weak web] in
        guard let web, !web.available, let responder = web.window?.firstResponder as? NSView,
          responder === web || responder.isDescendant(of: web) else { return }
        web.window?.makeFirstResponder(nil)
      }
    }
    context.coordinator.update(payload, in: web)
  }
  static func dismantleNSView(_ web: WebView, coordinator: Coordinator) {
    coordinator.active = false; web.stopLoading(); web.navigationDelegate = nil
  }
  final class WebView: WKWebView {
    var available = true
    override var acceptsFirstResponder: Bool { available && super.acceptsFirstResponder }
    override func hitTest(_ point: NSPoint) -> NSView? { available ? super.hitTest(point) : nil }
  }
  var payload: [String: Any] {
    // Reading the environment also invalidates the surface when the system
    // appearance changes without a preference write.
    var appearance = appearance
    if appearance.theme == "system" { appearance.theme = scheme == .dark ? "dark" : "light" }
    let dark = appearance.isDark, theme = appearance.activeCodeTheme
    let raw = appearance.themeShare(dark: dark).theme
    let identity = CodeSyntaxInput(path: AppearanceDiffPreview.path, diff: AppearanceDiffPreview.diff, themes: appearance.codeThemes).identity
    func side(_ lines: [ReviewDiffLine], _ side: GitHubPRCommentPosition.Side) -> [[String: Any]] {
      lines.map { line in
        let tokens = syntax.tokens(line, identity: identity, side: side) ?? [.init(content: String(line.text.dropFirst()),
          light: .init(color: nil, fontStyle: 0), dark: .init(color: nil, fontStyle: 0))]
        return ["number": side == .left ? line.oldLine! : line.newLine!,
          "change": line.kind == .deletion ? "deletion" : line.kind == .addition ? "addition" : "context",
          "tokens": tokens.map { token -> [String: Any] in
            let style = dark ? token.dark : token.light
            return ["content": token.content, "color": style.color ?? "", "style": style.fontStyle]
          }]
      }
    }
    let family = appearance.fontFamily(.code, dark: dark)
    let face = appearance.fontFace(.code, dark: dark)?.postscriptName
    // JSON string quoting is also valid for a CSS quoted family name.
    let quotedFace = face.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) }
    let font = [quotedFace, family.isEmpty ? nil : family, "ui-monospace, SFMono-Regular, Menlo, monospace"].compactMap { $0 }.joined(separator: ", ")
    return ["dark": dark, "size": appearance.codeSize, "font": font,
      "surface": raw.surface, "background": theme?.background ?? raw.surface,
      "foreground": theme?.foreground ?? raw.ink, "added": raw.semanticColors.diffAdded,
      "removed": raw.semanticColors.diffRemoved, "symbols": appearance.diffMarkerStyle == .symbols,
      "left": side(AppearanceDiffPreview.left, .left), "right": side(AppearanceDiffPreview.right, .right)]
  }
  @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
    var active = true; private var ready = false; private var pending: [String: Any]?
    func update(_ payload: [String: Any], in web: WKWebView) {
      pending = payload; guard active, ready else { return }
      web.callAsyncJavaScript("window.renderPreview(payload)", arguments: ["payload": payload], in: nil, in: .page) { _ in }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      guard active else { return }; ready = true; if let pending { update(pending, in: webView) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
      decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
  }
  static let document = #"""
  <!doctype html><html><head><meta charset="utf-8">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src 'none'; connect-src 'none'">
  <style>
  *{box-sizing:border-box}html,body{margin:0;width:100%;height:100%;overflow:hidden}
  body{font:var(--size)/1.8 var(--font);color:var(--fg);background:var(--surface)}
  main{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);height:100%}
  .pane{min-width:0;overflow-x:auto;overflow-y:hidden;overscroll-behavior-x:none;tab-size:2}
  .pane:first-child{border-right:1px solid var(--surface)}
  .rows{min-width:100%;width:max-content}
  .row{display:flex;min-width:100%;height:1.8em;white-space:pre}
  .number{width:4ch;flex:none;text-align:right;padding-right:1ch;user-select:none;color:color-mix(in lab,var(--fg) 65%,var(--bg))}
  .code{min-width:0;flex:1;padding-right:1ch}
  .indicator{width:1ch;flex:none;user-select:none;position:relative}
  .deletion{--base:var(--removed)}.addition{--base:var(--added)}
  .addition .code,.deletion .code,.addition .indicator,.deletion .indicator{background:color-mix(in lab,var(--bg) var(--line-mix),var(--base))}
  .addition .number,.deletion .number{color:var(--base);background:color-mix(in lab,var(--bg) var(--number-mix),var(--base))}
  body:not(.symbols) .addition .indicator:before,body:not(.symbols) .deletion .indicator:before{content:'';position:absolute;left:0;top:0;bottom:0;width:2px;background:var(--base)}
  .indicator{color:var(--base)}::selection{background:Highlight;color:HighlightText}
  .pane::-webkit-scrollbar{height:6px}.pane::-webkit-scrollbar-thumb{background:#8886;border-radius:3px}
  </style></head><body><main aria-label="主题差异预览"><div class="pane" aria-label="旧文件"><div class="rows"></div></div><div class="pane" aria-label="新文件"><div class="rows"></div></div></main>
  <script>
  function captureSelection(){
    const selection=getSelection();if(!selection.rangeCount)return null;
    function point(node,offset){const code=(node.nodeType===1?node:node.parentElement)?.closest('.code');if(!code)return null;
      const range=document.createRange();range.selectNodeContents(code);try{range.setEnd(node,offset)}catch{return null}
      return {code,offset:range.toString().length};}
    return {anchor:point(selection.anchorNode,selection.anchorOffset),focus:point(selection.focusNode,selection.focusOffset)};
  }
  function restoreSelection(saved){if(!saved?.anchor||!saved?.focus)return;
    function point(p){const walker=document.createTreeWalker(p.code,NodeFilter.SHOW_TEXT);let offset=p.offset,node;
      while(node=walker.nextNode()){if(offset<=node.length)return [node,offset];offset-=node.length}return [p.code,p.code.childNodes.length];}
    const a=point(saved.anchor),f=point(saved.focus);getSelection().setBaseAndExtent(...a,...f);
  }
  window.renderPreview=function(p){
    const saved=captureSelection(),style=document.body.style;
    for(const [key,value] of Object.entries({'--size':p.size+'px','--font':p.font,'--surface':p.surface,'--bg':p.background,'--fg':p.foreground,'--added':p.added,'--removed':p.removed,'--line-mix':p.dark?'80%':'88%','--number-mix':p.dark?'85%':'91%'}))style.setProperty(key,value);
    document.body.classList.toggle('symbols',p.symbols);document.body.style.colorScheme=p.dark?'dark':'light';
    for(const [index,lines] of [p.left,p.right].entries()){
      const rows=document.querySelectorAll('.rows')[index];
      for(const [i,line] of lines.entries()){
        let row=rows.children[i];if(!row){row=document.createElement('div');row.innerHTML='<span class="number"></span><span class="indicator"></span><span class="code"></span>';rows.append(row)}
        row.className='row '+line.change;row.children[0].textContent=line.number;
        row.children[1].textContent=p.symbols?(line.change==='addition'?'+':line.change==='deletion'?'-':' '):'';
        const code=row.children[2];
        for(const [j,token] of line.tokens.entries()){
          let span=code.children[j];if(!span){span=document.createElement('span');code.append(span)}
          if(span.textContent!==token.content)span.textContent=token.content;
          span.style.color=token.color;span.style.fontStyle=token.style&1?'italic':'';
          span.style.fontWeight=token.style&2?'bold':'';span.style.textDecoration=token.style&4?'underline':'';
        }
        while(code.children.length>line.tokens.length)code.lastChild.remove();
      }
    }
    restoreSelection(saved);document.body.dataset.ready='true';
  };
  </script></body></html>
  """#
}
