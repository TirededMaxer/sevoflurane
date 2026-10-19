import AppKit
import WebKit

@MainActor
enum NativeOverlayInput {
    private static var pressed: [ObjectIdentifier: NSView] = [:]

    static func deliver(_ packet: [String: Any], to popup: SteamWindow) {
        guard let window = popup.window, let content = window.contentView,
              let kind = packet["event"] as? String else { return }
        let web = popup.webView
        var flags: NSEvent.ModifierFlags = []
        for (name, flag) in [("shift", NSEvent.ModifierFlags.shift), ("ctrl", .control), ("alt", .option), ("meta", .command)] {
            if packet[name] as? Bool == true { flags.insert(flag) }
        }
        let id = ObjectIdentifier(web)
        let responder = window.firstResponder ?? web
        if kind.hasPrefix("composition") {
            guard let input = responder as? any NSTextInputClient else { return }
            let text = packet["text"] as? String ?? ""
            if kind == "compositionend" {
                input.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            } else {
                input.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0),
                                    replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            return
        }
        if kind == "keydown" || kind == "keyup" {
            let key = packet["key"] as? String ?? ""
            let code = packet["code"] as? String ?? ""
            let characters = key.count == 1 ? key : controlCharacter(code)
            guard let event = NSEvent.keyEvent(with: kind == "keydown" ? .keyDown : .keyUp,
                location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: packet["repeat"] as? Bool ?? false,
                keyCode: keyCodes[code] ?? 0) else { return }
            if kind == "keydown" { responder.keyDown(with: event) } else { responder.keyUp(with: event) }
            return
        }
        let x = (packet["x"] as? NSNumber)?.doubleValue ?? 0
        let y = (packet["y"] as? NSNumber)?.doubleValue ?? 0
        let point = NSPoint(x: x, y: content.bounds.height-y)
        let local = content.convert(point, to: nil)
        let view = pressed[id] ?? content.hitTest(content.superview?.convert(local, from: nil) ?? local) ?? web
        popup.relayReactHover(contentPoint: point, contentHeight: content.bounds.height)
        if kind == "wheel" {
            let dx = (packet["dx"] as? NSNumber)?.doubleValue ?? 0
            let dy = (packet["dy"] as? NSNumber)?.doubleValue ?? 0
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                   wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0) else { return }
            let screen = window.convertPoint(toScreen: local)
            cg.location = NSPoint(x: screen.x, y: SteamScreenSpace.flipLine-screen.y)
            guard let event = NSEvent(cgEvent: cg) else { return }
            let relative = Selector(("_eventRelativeToWindow:"))
            guard event.responds(to: relative),
                  let targeted = event.perform(relative, with: window)?.takeUnretainedValue() as? NSEvent else { return }
            web.scrollWheel(with: targeted); return
        }
        let button = packet["button"] as? Int ?? 0
        let right = button == 2
        let type: NSEvent.EventType
        if kind == "mousedown" {
            window.makeFirstResponder(web); pressed[id] = view
            type = right ? .rightMouseDown : .leftMouseDown
        } else if kind == "mouseup" { type = right ? .rightMouseUp : .leftMouseUp }
        else if pressed[id] != nil { type = .leftMouseDragged }
        else { type = .mouseMoved }
        guard let event = NSEvent.mouseEvent(with: type, location: local, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: packet["clicks"] as? Int ?? 1, pressure: kind == "mousedown" ? 1 : 0) else { return }
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseUp: view.mouseUp(with: event); pressed.removeValue(forKey: id)
        case .rightMouseDown: view.rightMouseDown(with: event)
        case .rightMouseUp: view.rightMouseUp(with: event); pressed.removeValue(forKey: id)
        case .leftMouseDragged: view.mouseDragged(with: event)
        default: view.mouseMoved(with: event)
        }
    }

    private static func controlCharacter(_ code: String) -> String {
        switch code {
        case "Enter", "NumpadEnter": "\r"
        case "Backspace": "\u{7f}"
        case "Tab": "\t"
        case "Escape": "\u{1b}"
        case "ArrowUp": "\u{f700}"
        case "ArrowDown": "\u{f701}"
        case "ArrowLeft": "\u{f702}"
        case "ArrowRight": "\u{f703}"
        case "Delete": "\u{f728}"
        case "Home": "\u{f729}"
        case "End": "\u{f72b}"
        case "PageUp": "\u{f72c}"
        case "PageDown": "\u{f72d}"
        default:
            if code.hasPrefix("F"), let n = Int(code.dropFirst()), (1...20).contains(n),
               let scalar = Unicode.Scalar(0xf703+n) { return String(scalar) }
            return ""
        }
    }

    private static let keyCodes: [String: UInt16] = [
        "KeyA":0,"KeyS":1,"KeyD":2,"KeyF":3,"KeyH":4,"KeyG":5,"KeyZ":6,"KeyX":7,"KeyC":8,"KeyV":9,
        "KeyB":11,"KeyQ":12,"KeyW":13,"KeyE":14,"KeyR":15,"KeyY":16,"KeyT":17,"Digit1":18,"Digit2":19,
        "Digit3":20,"Digit4":21,"Digit6":22,"Digit5":23,"Equal":24,"Digit9":25,"Digit7":26,"Minus":27,
        "Digit8":28,"Digit0":29,"BracketRight":30,"KeyO":31,"KeyU":32,"BracketLeft":33,"KeyI":34,"KeyP":35,
        "Enter":36,"KeyL":37,"KeyJ":38,"Quote":39,"KeyK":40,"Semicolon":41,"Backslash":42,"Comma":43,
        "Slash":44,"KeyN":45,"KeyM":46,"Period":47,"Tab":48,"Space":49,"Backquote":50,"Backspace":51,
        "Escape":53,"Home":115,"PageUp":116,"Delete":117,"End":119,"PageDown":121,
        "F1":122,"F2":120,"F3":99,"F4":118,"F5":96,"F6":97,"F7":98,"F8":100,"F9":101,"F10":109,"F11":103,"F12":111,
        "NumpadEnter":76,"Numpad0":82,"Numpad1":83,"Numpad2":84,"Numpad3":85,"Numpad4":86,"Numpad5":87,
        "Numpad6":88,"Numpad7":89,"Numpad8":91,"Numpad9":92,"NumpadDecimal":65,"NumpadAdd":69,"NumpadSubtract":78,
        "ArrowLeft":123,"ArrowRight":124,"ArrowDown":125,"ArrowUp":126,
    ]
}
