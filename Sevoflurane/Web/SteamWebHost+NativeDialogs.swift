import AppKit

extension SteamWebHost {
    /// Mirror the disabled-owner state of a real Win32 modal dialog. The
    /// original process still decides when the modal opens and closes.
    func setNativeDialogModal(_ blocked: Bool) {
        nativeDialogModal = blocked
        if blocked {
            for popup in popups.values {
                if let window = popup.nsWindow { applyNativeDialogModal(to: window) }
            }
        } else {
            for window in nativeDialogMouseStates.keyEnumerator() {
                guard let window = window as? NSWindow,
                      let previous = nativeDialogMouseStates.object(forKey: window) else { continue }
                window.ignoresMouseEvents = previous.boolValue
            }
            nativeDialogMouseStates.removeAllObjects()
        }
    }

    func applyNativeDialogModal(to window: NSWindow) {
        guard nativeDialogModal else { return }
        if nativeDialogMouseStates.object(forKey: window) == nil {
            nativeDialogMouseStates.setObject(NSNumber(value: window.ignoresMouseEvents), forKey: window)
        }
        window.ignoresMouseEvents = true
    }
}
