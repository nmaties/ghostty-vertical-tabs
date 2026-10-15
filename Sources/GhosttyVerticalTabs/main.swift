import AppKit
import ServiceManagement
import SwiftUI

enum DockSide: String {
    case left, right
}

/// A panel that takes clicks without pulling focus away from Ghostty.
final class SidebarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = TabsModel()
    private var panel: SidebarPanel!
    private var statusItem: NSStatusItem!
    private var timers: [Timer] = []

    private let width: CGFloat = 220
    private let gap: CGFloat = 6

    /// The spot every Ghostty window is stacked on: the frame of the front window,
    /// following it when you move or resize it.
    private var anchor: CGRect?
    private var lastFront: AXUIElement?

    private var dockSide: DockSide {
        get { DockSide(rawValue: UserDefaults.standard.string(forKey: "dockSide") ?? "") ?? .left }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "dockSide"); buildMenu(); tick() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = SidebarPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = ClickThroughHostingView(rootView: SidebarView(model: model))
        model.onDrag = { [weak self] phase in
            MainActor.assumeIsolated { self?.drag(phase) }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Ghostty Vertical Tabs")
        buildMenu()

        if !WindowStacker.isTrusted { WindowStacker.requestTrust() }
        if Ghostty.hidesTitlebar {
            Ghostty.scriptQueue.async { try? Ghostty.updateBlockIfOutdated() }
        } else {
            offerWindowPerTabSetup()
        }

        // Window position is cheap to read, so follow it closely; the tab list goes through AppleScript.
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTabsIfVisible() }
        })
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
                self?.refreshTabsIfVisible()
            }
        }
    }

    private func offerWindowPerTabSetup() {
        let alert = NSAlert()
        alert.messageText = "Hide Ghostty's title bar?"
        alert.informativeText = """
        Ghostty Vertical Tabs works best when Ghostty's own title bar and tab bar are hidden. \
        Ghostty then opens every new tab as its own window, and the sidebar stacks those windows \
        in one spot and switches between them.

        This adds `macos-titlebar-style = hidden`, plus 10 pt of padding around the terminal \
        unless you already set your own, to \(Ghostty.configURL.path). \
        You can undo it from the menu bar icon.
        """
        alert.addButton(withTitle: "Hide Title Bar")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { setHidesTitlebar(true) }
    }

    private func buildMenu() {
        let menu = NSMenu()
        let left = NSMenuItem(title: "Dock on Left", action: #selector(dockLeft), keyEquivalent: "")
        left.state = dockSide == .left ? .on : .off
        let right = NSMenuItem(title: "Dock on Right", action: #selector(dockRight), keyEquivalent: "")
        right.state = dockSide == .right ? .on : .off
        menu.addItem(left)
        menu.addItem(right)
        menu.addItem(.separator())
        let hide = NSMenuItem(title: "Hide Ghostty's Title Bar (One Window per Tab)", action: #selector(toggleTitlebar), keyEquivalent: "")
        hide.state = Ghostty.hidesTitlebar ? .on : .off
        menu.addItem(hide)
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Ghostty Vertical Tabs", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
    }

    @objc private func dockLeft() { dockSide = .left }
    @objc private func dockRight() { dockSide = .right }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
        buildMenu()
    }

    @objc private func toggleTitlebar() {
        setHidesTitlebar(!Ghostty.hidesTitlebar)
    }

    private func setHidesTitlebar(_ hide: Bool) {
        do {
            try Ghostty.setHidesTitlebar(hide)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        buildMenu()
        offerToReopenWindows(titlebarHidden: hide)
    }

    /// Ghostty only applies a title bar change to new windows, so the windows already open
    /// would keep the old look until reopened.
    private func offerToReopenWindows(titlebarHidden: Bool) {
        guard Ghostty.runningApp != nil else { return }
        // On first launch the sidebar hasn't loaded yet, so ask Ghostty. It lists windows
        // front to back; reversed, that's roughly the order they were opened in.
        let ids = model.tabs.isEmpty
            ? ((try? Ghostty.state())?.tabs.map(\.id).reversed() ?? [])
            : model.tabs.map(\.id)
        guard !ids.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Reopen your Ghostty windows?"
        alert.informativeText = """
        Ghostty only applies the title bar change to new windows. Reopen your \(ids.count) \
        \(ids.count == 1 ? "window" : "windows") in the same \(ids.count == 1 ? "folder" : "folders") \
        now so \(titlebarHidden ? "the title bar goes away" : "the title bar comes back")?

        Anything running in them stops. Ghostty asks first if a command is still running.
        """
        alert.addButton(withTitle: "Reopen Windows")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Ghostty.scriptQueue.async {
            try? Ghostty.reopen(windowIDs: ids)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.model.refresh() } }
        }
    }

    private func refreshTabsIfVisible() {
        guard panel.isVisible || Ghostty.isFrontmost else { return }
        model.refresh()
    }

    private func tick() {
        // The drag handler places everything itself while a drag is in progress.
        if dragStart != nil { return }
        guard Ghostty.runningApp != nil, Ghostty.isFrontmost else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        let frame: CGRect
        if Ghostty.hidesTitlebar && WindowStacker.isTrusted {
            if let focused = WindowStacker.focusedWindow() {
                frame = stack(focused.element, at: focused.frame)
            } else if let anchor, panel.isVisible {
                // A Ghostty dialog has focus; stay where the terminal windows are.
                frame = anchor
            } else {
                if panel.isVisible { panel.orderOut(nil) }
                return
            }
        } else if let front = Ghostty.frontWindowFrame() {
            // Normal titlebar or no Accessibility access: just follow the front window.
            frame = front
        } else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }

        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        // A fullscreen window leaves no room beside it.
        if let screen, frame.width >= screen.frame.width - 1 {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        place(beside: frame, on: screen)
    }

    /// When a different window gets focus (you switched tabs or opened one), move it onto
    /// the anchor. When the front window moves or resizes, the anchor follows it and every
    /// window behind it is moved along, so none is left showing at the old spot.
    private func stack(_ window: AXUIElement, at frame: CGRect) -> CGRect {
        defer { lastFront = window }
        let switched = lastFront.map { !CFEqual($0, window) } ?? true
        if switched, let anchor, frame != anchor {
            WindowStacker.move(window, to: anchor)
            return anchor
        }
        // While our own moves are still landing, the window's frame lags behind the anchor;
        // that isn't you moving it.
        if frame != anchor, !mover.isBusy {
            anchor = frame
            mover.moveAll(to: frame, except: window)
        }
        return frame
    }

    private let mover = StackMover()
    private var dragStart: CGRect?
    /// Set when the title bar is visible: windows aren't stacked, so only the front one moves.
    private var dragSingleWindow: AXUIElement?

    /// Moves the terminal, and the sidebar with it, while the grab bar is dragged.
    /// The sidebar moves right away; the windows move on a background queue that only ever
    /// applies the latest position.
    private func drag(_ phase: DragPhase) {
        switch phase {
        case .began:
            guard WindowStacker.isTrusted else {
                // Moving windows needs Accessibility. Ask, and show the notice in the sidebar.
                WindowStacker.requestTrust()
                model.needsAccessibility = true
                return
            }
            guard let focused = WindowStacker.focusedWindow() else { return }
            if Ghostty.hidesTitlebar {
                dragStart = anchor ?? focused.frame
                dragSingleWindow = nil
            } else {
                dragStart = focused.frame
                dragSingleWindow = focused.element
            }
        case .moved(let offset):
            guard let dragStart else { return }
            let frame = dragStart.offsetBy(dx: offset.width, dy: offset.height)
            if let window = dragSingleWindow {
                WindowStacker.move(window, to: frame)
            } else {
                anchor = frame
                mover.moveAll(to: frame)
            }
            let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
            place(beside: frame, on: screen)
        case .ended:
            if dragSingleWindow == nil, dragStart != nil, let anchor { mover.moveAll(to: anchor) }
            dragStart = nil
            dragSingleWindow = nil
        }
    }

    private func place(beside window: CGRect, on screen: NSScreen?) {
        let bounds = screen?.visibleFrame ?? window
        let fitsLeft = window.minX - gap - width >= bounds.minX
        let fitsRight = window.maxX + gap + width <= bounds.maxX
        let x: CGFloat
        switch dockSide {
        case .left:
            x = fitsLeft || !fitsRight ? window.minX - gap - width : window.maxX + gap
        case .right:
            x = fitsRight || !fitsLeft ? window.maxX + gap : window.minX - gap - width
        }
        // If neither side has room, keep the sidebar on screen over the window's edge.
        let clampedX = min(max(x, bounds.minX), bounds.maxX - width)
        let frame = NSRect(x: clampedX, y: window.minY, width: width, height: window.height)

        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible {
            // Show right away with the last known tabs; the AppleScript round trip comes after.
            panel.orderFrontRegardless()
            DispatchQueue.main.async { [weak self] in self?.model.refresh() }
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
