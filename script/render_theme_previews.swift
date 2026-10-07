// Offline resource generation. No window, navigation, network or personal data.
import AppKit
import WebKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
_ = NSApplication.shared
let configuration = WKWebViewConfiguration()
configuration.websiteDataStore = .nonPersistent()
let web = WKWebView(frame: .zero, configuration: configuration)
Task { @MainActor in
  do {
    for name in ["light", "dark", "system-light", "system-dark"] {
      let svg = try String(contentsOf: directory.appendingPathComponent(name + ".svg"), encoding: .utf8)
      for scale in 1...3 { for mask in [false, true] {
        let output = try await web.callAsyncJavaScript(#"""
          const svg=new DOMParser().parseFromString(source,'image/svg+xml').documentElement;
          const w=Number(svg.getAttribute('width')),h=Number(svg.getAttribute('height'));
          for(const node of [svg,...svg.querySelectorAll('*')]){
            if(mask){
              if(node.closest('defs'))continue;
              if(node.hasAttribute('fill'))node.setAttribute('fill',node.getAttribute('fill')==='currentColor'?'white':'none');
              if(node.hasAttribute('stroke'))node.setAttribute('stroke','none');
            }else if(node.getAttribute('fill')==='currentColor')node.setAttribute('fill','transparent');
          }
          svg.setAttribute('width',String(w*scale));svg.setAttribute('height',String(h*scale));
          const image=new Image();await new Promise((resolve,reject)=>{image.onload=resolve;image.onerror=reject;
            image.src='data:image/svg+xml;charset=utf-8,'+encodeURIComponent(new XMLSerializer().serializeToString(svg))});
          const canvas=document.createElement('canvas');canvas.width=w*scale;canvas.height=h*scale;
          canvas.getContext('2d',{colorSpace:'srgb'}).drawImage(image,0,0);
          return canvas.toDataURL('image/png').split(',')[1];
          """#, arguments: ["source": svg, "mask": mask, "scale": scale], in: nil, contentWorld: .defaultClient)
        guard let encoded = output as? String, let data = Data(base64Encoded: encoded) else { throw CocoaError(.fileReadCorruptFile) }
        try data.write(to: directory.appendingPathComponent(name + (mask ? "-accent" : "-base") + (scale == 1 ? "" : "@\(scale)x") + ".png"))
      } }
    }
    print("Rendered four theme previews and four accent masks at 1×, 2× and 3× using WebKit")
    exit(0)
  } catch { print(error); exit(1) }
}
NSApplication.shared.run()
