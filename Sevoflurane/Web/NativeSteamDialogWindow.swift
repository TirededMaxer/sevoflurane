import AppKit
import CoreText
import WebKit

/// Standard Win32 controls retain their original coordinates, text, font and
/// state. WebKit draws their vector text; the original HWND executes actions.
/// Custom owner-drawn VGUI canvases are deliberately outside this adapter.
@MainActor
final class NativeSteamDialogWindow: NSObject, NSWindowDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    let window: OriginalSteamDialogPanel
    let webView: WKWebView
    private(set) var dialog: SteamNativeDialog
    private let send: ([String]) -> Void
    private let fonts: OriginalDialogFonts
    private var originalClosed = false
    private var ready = false

    init?(dialog: SteamNativeDialog, send: @escaping ([String]) -> Void) {
        guard dialog.canPresent, let width = dialog.clientWidth, let height = dialog.clientHeight else { return nil }
        self.dialog = dialog
        self.send = send
        let fontHandler = OriginalDialogFonts(bottle: SteamBottle.root)
        fonts = fontHandler
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(fontHandler, forURLScheme: OriginalDialogFonts.scheme)
        webView = OriginalDialogWebView(frame: .zero, configuration: configuration)
        window = OriginalSteamDialogPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        super.init()
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.managed, .fullScreenNone]
        window.delegate = self
        window.contentView = webView
        window.hasShadow = true
        window.title = dialog.title
        window.setAccessibilityIdentifier("steam-original-dialog-\(dialog.handle)")
        configuration.userContentController.add(self, name: "originalDialog")
        webView.navigationDelegate = self
        webView.isInspectable = true
        webView.loadHTMLString(Self.document, baseURL: URL(string: "about:blank"))
        window.standardWindowButton(.closeButton)?.isEnabled = dialog.canClose == true
        window.center()
    }

    func showOriginal() {
        Task { [weak self] in
            guard let self, !originalClosed else { return }
            _ = await DesktopSpacePlacement.place(window)
            guard !originalClosed else { return }
            Activation().bringAppForward()
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(webView)
        }
    }

    /// A click can leave the original dialog alive after validation. Only an
    /// original disappearance tears down the corresponding WebKit window.
    func originalDidClose() {
        guard !originalClosed else { return }
        originalClosed = true
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "originalDialog")
        webView.stopLoading()
        window.close()
    }

    func windowShouldClose(_: NSWindow) -> Bool {
        if originalClosed { return true }
        requestClose()
        return false
    }

    func update(_ snapshot: SteamNativeDialog) {
        dialog = snapshot
        window.title = snapshot.title
        window.standardWindowButton(.closeButton)?.isEnabled = snapshot.canClose == true
        if let width = snapshot.clientWidth, let height = snapshot.clientHeight {
            let size = NSSize(width: width, height: height)
            if window.contentView?.frame.size != size { window.setContentSize(size) }
        }
        guard ready else { return }
        guard let data = try? JSONEncoder().encode(snapshot), let json = String(data: data, encoding: .utf8) else { return }
        let families = Set((snapshot.controls ?? []).compactMap { $0.font?.family } + [snapshot.font?.family].compactMap { $0 })
        let sources = fonts.sources(for: families)
        guard let fontData = try? JSONEncoder().encode(sources), let fontJSON = String(data: fontData, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.updateOriginal(\(json),\(fontJSON))")
    }

    func webView(_: WKWebView, didFinish _: WKNavigation!) {
        ready = true
        update(dialog)
    }

    /// This page has no remote content and no navigation surface. Font scheme
    /// requests are served by an exact in-memory URL allowlist below.
    func webView(_: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        action.request.url?.absoluteString == "about:blank" ? .allow : .cancel
    }

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !originalClosed, message.frameInfo.isMainFrame, message.webView === webView,
              let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        if action == "close" { requestClose(); return }
        guard let handleText = body["handle"] as? String, let handle = UInt64(handleText),
              let control = dialog.controls?.first(where: { $0.handle == handle }), control.enabled else { return }
        let args = ["control", String(dialog.handle), String(dialog.pid), String(handle)]
        switch action {
        case "click":
            guard control.className.lowercased() == "button", control.style & 15 != 7 else { return }
            send(args + ["click"])
        case "focus":
            send(args + ["focus"])
        case "text":
            guard control.className.lowercased() == "edit", control.style & 0x800 == 0,
                  let text = body["text"] as? String else { return }
            send(args + ["text", text])
        default: break
        }
    }

    private func requestClose() {
        guard dialog.canClose == true else { return }
        send(["answer", String(dialog.handle), String(dialog.pid), "0"])
    }

    /// Every visible string is copied from the original Win32 snapshot. The
    /// classic control primitives use observed Win32 colors, never AppKit widgets.
    static let document = #"""
    <!doctype html><html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src sevo-dialog-font:; connect-src 'none'">
    <style>
    *{box-sizing:border-box}html,body{margin:0;overflow:hidden;width:100%;height:100%}
    body{background:var(--face);color:var(--windowText);font-family:sans-serif}
    #client{position:absolute;background:var(--face);overflow:hidden}
    .control{position:absolute;margin:0;line-height:normal;white-space:pre-wrap}
    .button{appearance:none;color:var(--buttonText);background:var(--face);border:1px solid var(--shadow);border-top-color:var(--light);border-left-color:var(--light);border-radius:0;padding:1px 4px;overflow:hidden;text-align:center}
    .button:active{border-color:var(--shadow);border-bottom-color:var(--light);border-right-color:var(--light)}
    .button.default{outline:1px solid var(--windowText);outline-offset:-2px}
    .control:focus-visible{outline:1px dotted var(--windowText);outline-offset:-4px}
    .control:disabled,.disabled{color:var(--grayText)!important;cursor:default}
    .static{overflow:hidden;user-select:none}
    .toggle{display:flex;align-items:center;gap:4px;user-select:none;outline:none}
    .toggle input{appearance:none;flex:none;margin:0;width:13px;height:13px;background:var(--window);border:1px inset var(--shadow);position:relative}
    .toggle input[type=radio]{border-radius:50%}.toggle input:checked:after{content:'';position:absolute;inset:3px;background:var(--windowText)}
    .toggle input[type=radio]:checked:after{border-radius:50%}.toggle input:indeterminate:after{content:'';position:absolute;inset:3px;background:var(--grayText)}
    .edit{appearance:none;resize:none;border:1px inset var(--shadow);border-radius:0;background:var(--window);color:var(--windowText);padding:1px 2px;white-space:pre;outline:none}
    .edit.multiline{white-space:pre-wrap;overflow:auto}.group{border:1px solid var(--shadow);padding:0 6px}.group legend{padding:0 3px;white-space:pre}
    progress{appearance:none;border:1px inset var(--shadow);background:var(--face)}progress::-webkit-progress-bar{background:var(--face)}progress::-webkit-progress-value{background:var(--highlight)}
    img.control{object-fit:contain}::selection{background:var(--highlight);color:var(--highlightText)}
    </style><style id="fonts"></style></head><body>
    <main id="client"></main>
    <script>
    'use strict';
    let original=null;const elements=new Map();const client=document.getElementById('client');
    function send(action,handle,text){const value={action:action};if(handle!==undefined)value.handle=String(handle);if(text!==undefined)value.text=text;window.webkit.messageHandlers.originalDialog.postMessage(value)}
    function displayTitle(value){return String(value).replace(/&&/g,'\u0000').replace(/&/g,'').replace(/\u0000/g,'&')}
    function rgb(value){return Array.isArray(value)&&value.length===3&&value.every(x=>Number.isInteger(x)&&x>=0&&x<=255)?'rgb('+value.join(',')+')':null}
    function applyFont(el,font){if(!font)return;el.style.fontFamily=JSON.stringify(font.family)+',sans-serif';el.style.fontSize=Math.max(1,font.pixelHeight)+'px';el.style.fontWeight=font.weight;el.style.fontStyle=font.italic?'italic':'normal';el.style.textDecoration=font.underline?'underline':'none'}
    function make(c){
      const kind=c.className.toLowerCase(),type=c.style&15;let el;
      if(kind==='button'){
        if(type===7){el=document.createElement('fieldset');el.className='control group';el.appendChild(document.createElement('legend'))}
        else if([2,3,4,5,6,9].includes(type)){el=document.createElement('label');el.className='control toggle';const input=document.createElement('input');input.type=[4,9].includes(type)?'radio':'checkbox';el.append(input,document.createElement('span'));input.addEventListener('click',ev=>{ev.preventDefault();send('click',c.handle)})}
        else{el=document.createElement('button');el.className='control button';el.type='button';el.addEventListener('click',()=>send('click',c.handle))}
      }else if(kind==='edit'){
        el=document.createElement(c.style&4?'textarea':'input');el.className='control edit'+(c.style&4?' multiline':'');if(el.tagName==='INPUT')el.type=c.password?'password':'text';
        el.addEventListener('input',ev=>{if(!ev.isComposing)send('text',c.handle,el.value)});el.addEventListener('compositionend',()=>send('text',c.handle,el.value));
      }else if(kind==='msctls_progress32'){el=document.createElement('progress');el.className='control'}
      else if(kind==='static'&&(c.style&31)===3){el=document.createElement('img');el.className='control';el.alt=''}
      else{el=document.createElement('div');el.className='control static'}
      el.dataset.handle=String(c.handle);el.dataset.kind=kind;el.dataset.type=String(c.style);el.addEventListener('focusin',()=>send('focus',c.handle));return el;
    }
    function update(c,el){
      const kind=c.className.toLowerCase(),type=c.style&15;
      Object.assign(el.style,{left:c.x+'px',top:c.y+'px',width:c.width+'px',height:c.height+'px'});applyFont(el,c.font);
      if(rgb(c.textColor))el.style.color=rgb(c.textColor);if(rgb(c.backgroundColor)&&kind==='edit')el.style.backgroundColor=rgb(c.backgroundColor);
      el.classList.toggle('disabled',!c.enabled);el.classList.toggle('default',!!c.default);const input=el.querySelector('input');const focusable=input||el;
      focusable.disabled=!c.enabled;focusable.tabIndex=c.tabStop&&c.enabled?0:-1;
      if(kind==='button'){
        if(type===7)el.querySelector('legend').textContent=displayTitle(c.text);
        else if(input){el.querySelector('span').textContent=displayTitle(c.text);input.checked=c.checkState===1;input.indeterminate=c.checkState===2;el.style.flexDirection=(c.style&0x20)?'row-reverse':'row'}
        else{el.textContent=displayTitle(c.text);el.style.textAlign=(c.style&0x300)===0x100?'left':(c.style&0x300)===0x200?'right':'center';el.style.whiteSpace=(c.style&0x2000)?'pre-wrap':'pre'}
      }else if(kind==='edit'){
        el.readOnly=!!(c.style&0x800);if(!c.password&&document.activeElement!==el)el.value=c.text;
      }else if(kind==='msctls_progress32'){el.max=Math.max(1,(c.maximum||100)-(c.minimum||0));el.value=(c.value||0)-(c.minimum||0)}
      else if(el.tagName==='IMG'){
        if(c.iconBGRA&&/^[0-9a-f]{8192}$/.test(c.iconBGRA)){const bytes=Uint8ClampedArray.from(c.iconBGRA.match(/../g),x=>parseInt(x,16));for(let i=0;i<bytes.length;i+=4){const b=bytes[i];bytes[i]=bytes[i+2];bytes[i+2]=b;const a=bytes[i+3];if(a>0&&a<255)for(let j=0;j<3;j++)bytes[i+j]=Math.min(255,Math.round(bytes[i+j]*255/a))}const canvas=document.createElement('canvas');canvas.width=32;canvas.height=32;canvas.getContext('2d').putImageData(new ImageData(bytes,32,32),0,0);el.src=canvas.toDataURL()}
      }else{el.textContent=(c.style&0x80)?c.text:displayTitle(c.text);el.style.textAlign=(c.style&31)===1?'center':(c.style&31)===2?'right':'left'}
    }
    window.updateOriginal=function(snapshot,fontSources){
      original=snapshot;
      document.getElementById('fonts').textContent=Object.entries(fontSources).map(([family,url])=>'@font-face{font-family:'+JSON.stringify(family)+';src:url('+JSON.stringify(url)+')}').join('\n');
      for(const key of ['face','buttonText','window','windowText','highlight','highlightText','shadow','light','grayText','caption','captionText']){const value=rgb(snapshot[key]);if(value)document.documentElement.style.setProperty('--'+key,value)}
      Object.assign(client.style,{left:'0px',top:'0px',width:snapshot.clientWidth+'px',height:snapshot.clientHeight+'px'});
      const current=new Set(snapshot.controls.map(c=>String(c.handle)));for(const [key,el]of elements)if(!current.has(key)){el.remove();elements.delete(key)}
      for(const c of snapshot.controls){const key=String(c.handle);let el=elements.get(key);if(el&&(el.dataset.kind!==c.className.toLowerCase()||el.dataset.type!==String(c.style))){el.remove();elements.delete(key);el=null}if(!el){el=make(c);elements.set(key,el);client.append(el)}update(c,el)}
      // Preserve original enumeration/Tab order while retaining live IME nodes.
      const live=document.activeElement;if(!live||live===document.body){const first=client.querySelector('[tabindex="0"]');if(first)first.focus()}
    };
    document.addEventListener('keydown',e=>{
      if(!original||e.isComposing)return;
      if(e.key==='Tab'){
        const order=original.controls.filter(c=>c.tabStop&&c.enabled);if(!order.length)return;
        const active=document.activeElement&&document.activeElement.closest('[data-handle]');
        const index=order.findIndex(c=>active&&String(c.handle)===active.dataset.handle);
        const target=index<0?(e.shiftKey?order.length-1:0):(index+(e.shiftKey?-1:1)+order.length)%order.length;
        const next=order[target];
        const node=elements.get(String(next.handle));if(node){e.preventDefault();(node.querySelector('input')||node).focus()}return;
      }
      if(e.key==='Escape'){const cancel=original.controls.find(c=>c.id===2&&c.enabled&&c.className.toLowerCase()==='button');if(cancel){e.preventDefault();send('click',cancel.handle)}else if(original.canClose){e.preventDefault();send('close')}}
      if(e.key==='Enter'){
        const focused=original.controls.find(c=>String(c.handle)===(document.activeElement&&document.activeElement.dataset.handle));
        if(focused&&focused.className.toLowerCase()==='edit'&&(focused.style&4)&&(focused.style&0x1000))return;
        const button=focused&&focused.className.toLowerCase()==='button'?focused:original.controls.find(c=>c.default&&c.enabled);
        if(button){e.preventDefault();send('click',button.handle)}
      }
    });
    </script></body></html>
    """#
}

@MainActor
private final class OriginalDialogWebView: WKWebView {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        Activation().bringAppForward()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

@MainActor
final class OriginalSteamDialogPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Font URLs contain opaque IDs only. Sources are resolved under the selected
/// bottle's Fonts directory; symlinks escaping that directory are never served.
@MainActor
final class OriginalDialogFonts: NSObject, WKURLSchemeHandler {
    static let scheme = "sevo-dialog-font"
    private let root: URL
    private var files: [String: URL] = [:]
    private var families: [String: String] = [:]
    private var familyScores: [String: Double] = [:]
    private var indexed = false

    init(bottle: URL) {
        root = bottle.appendingPathComponent("drive_c/windows/Fonts").resolvingSymlinksInPath().standardizedFileURL
        super.init()
    }

    func sources(for requested: Set<String>) -> [String: String] {
        if !indexed {
            indexed = true
            let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let file = Self.admittedFont(url, root: root),
                      let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor] else { continue }
                for descriptor in descriptors {
                    guard let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String else { continue }
                    let key = family.lowercased()
                    let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [String: Any] ?? [:]
                    let weight = (traits[kCTFontWeightTrait as String] as? NSNumber)?.doubleValue ?? 0
                    let slant = (traits[kCTFontSlantTrait as String] as? NSNumber)?.doubleValue ?? 0
                    let score = abs(weight) + abs(slant)
                    if score < (familyScores[key] ?? .infinity) {
                        familyScores[key] = score
                        let token = String(files.count)
                        files[token] = file
                        families[key] = token
                    }
                }
            }
        }
        return Dictionary(uniqueKeysWithValues: requested.compactMap { family in
            guard let token = families[family.lowercased()] else { return nil }
            return (family, "\(Self.scheme)://font/\(token)")
        })
    }

    nonisolated static func admittedFont(_ candidate: URL, root: URL) -> URL? {
        let file = candidate.resolvingSymlinksInPath().standardizedFileURL
        let parent = root.resolvingSymlinksInPath().standardizedFileURL
        guard ["ttf", "otf", "ttc"].contains(file.pathExtension.lowercased()),
              file.deletingLastPathComponent() == parent,
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 64 * 1024 * 1024 else { return nil }
        return file
    }

    func webView(_: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.scheme == Self.scheme, url.host == "font", url.query == nil,
              let file = files[String(url.path.dropFirst())],
              Self.admittedFont(file, root: root) != nil, let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let mime = file.pathExtension.lowercased() == "otf" ? "font/otf" : file.pathExtension.lowercased() == "ttc" ? "font/collection" : "font/ttf"
        // WKURLSchemeTask explicitly requires CORS headers for cross-origin fonts.
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
            "Content-Type": mime, "Content-Length": String(data.count), "Access-Control-Allow-Origin": "*",
        ]) else { task.didFailWithError(URLError(.badServerResponse)); return }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_: WKWebView, stop _: any WKURLSchemeTask) {}
}
