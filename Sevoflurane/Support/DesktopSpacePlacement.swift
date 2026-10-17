import AppKit
import Darwin
import ObjectiveC.runtime

/// Desktop/login windows must belong to an actual user Desktop before they
/// are shown. Collection behaviors alone did not prevent a window created
/// from the menu-bar app from joining Chrome's fullscreen Space on macOS 27.
@MainActor
enum DesktopSpacePlacement {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopyDisplays = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopyMemberships = @convention(c) (Int32, UInt64, CFArray) -> Unmanaged<CFArray>?

    private struct API {
        let connection: Int32
        let displays: CopyDisplays
        let memberships: CopyMemberships
    }

    private static let api: API? = {
        guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let main = dlsym(library, "SLSMainConnectionID"),
              let displays = dlsym(library, "SLSCopyManagedDisplaySpaces"),
              let memberships = dlsym(library, "SLSCopySpacesForWindows") else { return nil }
        return API(connection: unsafeBitCast(main, to: MainConnection.self)(),
                   displays: unsafeBitCast(displays, to: CopyDisplays.self),
                   memberships: unsafeBitCast(memberships, to: CopyMemberships.self))
    }()

    static func memberships(of window: NSWindow) -> [UInt64] {
        guard let api else { return [] }
        let windows = [NSNumber(value: window.windowNumber)] as CFArray
        return (api.memberships(api.connection, 7, windows)?.takeRetainedValue() as? [NSNumber] ?? [])
            .map(\.uint64Value)
    }

    private static func spaceID(_ raw: [String: Any]) -> UInt64? {
        (raw["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? (raw["id64"] as? NSNumber)?.uint64Value
    }

    private static func target(for window: NSWindow) -> UInt64? {
        guard let api,
              let displays = api.displays(api.connection)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        let screen = window.screen ?? NSScreen.main
        let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let uuid = displayID.flatMap { CGDisplayCreateUUIDFromDisplayID($0)?.takeRetainedValue() }
            .map { CFUUIDCreateString(nil, $0) as String }
        let display = displays.first { row in
            let key = row["Display Identifier"] as? String
            return key == "Main" || key == uuid || key == displayID.map(String.init)
        } ?? (displays.count == 1 ? displays.first : nil)
        guard let display,
              let spaces = display["Spaces"] as? [[String: Any]] else { return nil }
        return destination(in: spaces, current: (display["Current Space"] as? [String: Any]).flatMap(spaceID),
                           memberships: memberships(of: window))
    }

    static func destination(in spaces: [[String: Any]], current: UInt64?, memberships: [UInt64]) -> UInt64? {
        let desktopIDs = spaces.filter { ($0["type"] as? NSNumber)?.intValue == 0 }.compactMap(spaceID)
        if memberships.count == 1, let existing = memberships.first, desktopIDs.contains(existing) { return existing }
        if let current, desktopIDs.contains(current) { return current }
        let currentIndex = spaces.firstIndex { spaceID($0) == current } ?? 0
        return spaces.enumerated().filter { ($0.element["type"] as? NSNumber)?.intValue == 0 }
            .min { abs($0.offset-currentIndex) < abs($1.offset-currentIndex) }.flatMap { spaceID($0.element) }
    }

    /// The operation is resolved dynamically and receives this process's own
    /// NSWindow only. Its result is asynchronous, so membership is re-read
    /// before ordering the visible window or requesting keyboard focus.
    /// SPI signatures: WindowKit SystemBridge/WindowStash.swift and SkyLight
    /// SLSBridgedSpaceAddWindowsAndRemoveFromSpacesOperation.
    private static func requestMove(_ window: NSWindow, to target: UInt64) -> AnyObject? {
        guard NSApp.window(withWindowNumber: window.windowNumber) === window,
              let cls = NSClassFromString("SLSBridgedSpaceAddWindowsAndRemoveFromSpacesOperation"),
              let initializeMethod = class_getInstanceMethod(cls, NSSelectorFromString("initWithSpaceID:windows:options:")),
              let performMethod = class_getInstanceMethod(cls, NSSelectorFromString("performWithWMBridgeDelegate")),
              let allocation = class_createInstance(cls, 0) as AnyObject? else { return nil }
        typealias Initialize = @convention(c) (AnyObject, Selector, UInt64, NSArray, UInt32) -> AnyObject?
        typealias Perform = @convention(c) (AnyObject, Selector) -> Void
        let initialize = unsafeBitCast(method_getImplementation(initializeMethod), to: Initialize.self)
        guard let operation = initialize(allocation, NSSelectorFromString("initWithSpaceID:windows:options:"),
                                         target, [NSNumber(value: window.windowNumber)], 7) else { return nil }
        unsafeBitCast(method_getImplementation(performMethod), to: Perform.self)(
            operation, NSSelectorFromString("performWithWMBridgeDelegate"))
        return operation
    }

    static func place(_ window: NSWindow) async -> Bool {
        // A user choosing Steam's own fullscreen button is still allowed.
        if window.styleMask.contains(.fullScreen) { return true }
        guard let destination = target(for: window) else {
            EventLog.shared.log(.window, "desktop Space unavailable for window \(window.windowNumber)")
            return false
        }
        if memberships(of: window) == [destination] { return true }
        let alpha = window.alphaValue
        window.alphaValue = 0
        window.orderBack(nil)
        defer { window.orderOut(nil); window.alphaValue = alpha }
        guard let operation = requestMove(window, to: destination) else {
            EventLog.shared.log(.window, "desktop Space move unavailable for window \(window.windowNumber)")
            return false
        }
        // Keep the operation alive through the bounded asynchronous handoff.
        for _ in 0..<30 {
            if memberships(of: window) == [destination] {
                withExtendedLifetime(operation) {}
                EventLog.shared.log(.window, "desktop Space confirmed: window \(window.windowNumber), space \(destination)")
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        withExtendedLifetime(operation) {}
        EventLog.shared.log(.window, "desktop Space move failed: window \(window.windowNumber), wanted \(destination), got \(memberships(of: window))")
        return false
    }
}
