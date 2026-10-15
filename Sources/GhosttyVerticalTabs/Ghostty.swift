import AppKit

/// One entry in the sidebar. In window-per-tab mode every Ghostty window is a tab.
struct GhosttyTab: Identifiable, Equatable {
    let id: String
    let title: String
    let directory: String
}

struct GhosttyState: Equatable {
    let frontWindowID: String
    let tabs: [GhosttyTab]
}

enum GhosttyError: Error {
    case notAllowed
    case script(String)
}

/// Talks to Ghostty through its AppleScript dictionary (Ghostty 1.3+).
enum Ghostty {
    static let bundleID = "com.mitchellh.ghostty"

    static var runningApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    // Field and record separators: titles can contain tabs and newlines, these
    // ASCII control characters effectively never show up in them.
    private static let fieldSep = "\u{1F}"
    private static let recordSep = "\u{1E}"

    private static let listScript = """
    set fs to character id 31
    set rs to character id 30
    tell application id "\(bundleID)"
        if (count of windows) is 0 then return ""
        set out to (id of front window) as text
        repeat with w in windows
            set nm to ""
            set cwd to ""
            try
                set t to selected tab of w
                set nm to name of t
                set cwd to working directory of focused terminal of t
            end try
            set out to out & rs & (id of w) & fs & nm & fs & cwd
        end repeat
        return out
    end tell
    """

    /// Ghostty's windows (in z-order, front first), or nil when it has none.
    /// Only call this while Ghostty is running: AppleScript would otherwise launch it.
    static func state() throws -> GhosttyState? {
        let output = try run(listScript)
        if output.isEmpty { return nil }
        var records = output.components(separatedBy: recordSep)
        let frontID = records.removeFirst()
        let tabs = records.compactMap { record -> GhosttyTab? in
            let f = record.components(separatedBy: fieldSep)
            guard f.count == 3 else { return nil }
            return GhosttyTab(id: f[0], title: f[1], directory: f[2])
        }
        return GhosttyState(frontWindowID: frontID, tabs: tabs)
    }

    static func activate(windowID: String) throws {
        _ = try run("""
        tell application id "\(bundleID)"
            activate window (window id "\(escape(windowID))")
            activate
        end tell
        """)
    }

    static func close(windowID: String) throws {
        _ = try run("""
        tell application id "\(bundleID)"
            close window (window id "\(escape(windowID))")
        end tell
        """)
    }

    static func newWindow(directory: String?) throws {
        let setDir = directory.map { "set initial working directory of cfg to \"\(escape($0))\"" } ?? ""
        _ = try run("""
        tell application id "\(bundleID)"
            set cfg to new surface configuration
            \(setDir)
            new window with configuration cfg
            activate
        end tell
        """)
    }

    /// Frame of Ghostty's frontmost on-screen window, in AppKit (bottom-left origin) coordinates.
    static func frontWindowFrame() -> CGRect? {
        guard let pid = runningApp?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        // The list is ordered front to back.
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 100, bounds.height > 100
            else { continue }
            return Screen.toAppKit(bounds)
        }
        return nil
    }

    // MARK: Config

    private static let blockStart = "# >>> ghostty-vertical-tabs >>>"
    private static let blockEnd = "# <<< ghostty-vertical-tabs <<<"

    /// Ghostty reads the XDG path first if it exists, otherwise the macOS Application Support one.
    static var configURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let xdg = home.appendingPathComponent(".config/ghostty/config")
        if FileManager.default.fileExists(atPath: xdg.path) { return xdg }
        return home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty/config.ghostty")
    }

    static var hidesTitlebar: Bool {
        (try? String(contentsOf: configURL, encoding: .utf8))?.contains(blockStart) ?? false
    }

    /// Adds or removes our block in Ghostty's config. With the titlebar hidden Ghostty opens
    /// every new tab as its own window, which is what the sidebar expects.
    static func setHidesTitlebar(_ hide: Bool) throws {
        let url = configURL
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if let start = text.range(of: blockStart), let end = text.range(of: blockEnd, range: start.upperBound..<text.endIndex) {
            var removeEnd = end.upperBound
            if removeEnd < text.endIndex, text[removeEnd] == "\n" { removeEnd = text.index(after: removeEnd) }
            text.removeSubrange(start.lowerBound..<removeEnd)
        }
        if hide {
            if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
            text += """
            \(blockStart)
            # Added by Ghostty Vertical Tabs: no titlebar or tab bar, every tab is a window.
            macos-titlebar-style = hidden
            \(blockEnd)

            """
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        if runningApp != nil {
            _ = try? run("""
            tell application id "\(bundleID)"
                if (count of windows) > 0 then perform action "reload_config" on focused terminal of selected tab of front window
            end tell
            """)
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func run(_ source: String) throws -> String {
        guard let script = NSAppleScript(source: source) else { throw GhosttyError.script("Could not compile script") }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            // -1743: the user has not allowed this app to control Ghostty.
            if (errorInfo[NSAppleScript.errorNumber] as? Int) == -1743 { throw GhosttyError.notAllowed }
            throw GhosttyError.script(errorInfo[NSAppleScript.errorMessage] as? String ?? "AppleScript error")
        }
        return result.stringValue ?? ""
    }
}

enum Screen {
    /// Converts between the top-left origin used by CoreGraphics and Accessibility
    /// and the bottom-left origin used by AppKit. The conversion is its own inverse.
    static func toAppKit(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// Moves Ghostty windows with the Accessibility API so every "tab" sits in the same spot.
enum WindowStacker {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Ghostty's focused terminal window and its frame (AppKit coordinates).
    /// Dialogs and panels (update prompts, settings) are skipped.
    static func focusedWindow() -> (element: AXUIElement, frame: CGRect)? {
        guard isTrusted, let pid = Ghostty.runningApp?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        guard let window: AXUIElement = attribute(app, kAXFocusedWindowAttribute),
              let subrole: String = attribute(window, kAXSubroleAttribute),
              subrole == kAXStandardWindowSubrole,
              let positionValue: AXValue = attribute(window, kAXPositionAttribute),
              let sizeValue: AXValue = attribute(window, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return (window, Screen.toAppKit(CGRect(origin: origin, size: size)))
    }

    /// Gives a window the given frame (AppKit coordinates).
    static func move(_ window: AXUIElement, to frame: CGRect) {
        let target = Screen.toAppKit(frame)
        var origin = target.origin
        var size = target.size
        // Size, then position, then size again: macOS clamps the size to the screen at the old position.
        if let sizeValue = AXValueCreate(.cgSize, &size), let originValue = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originValue)
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
