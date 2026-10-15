import SwiftUI

@MainActor
final class TabsModel: ObservableObject {
    @Published private(set) var tabs: [GhosttyTab] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var needsAutomation = false
    @Published var needsAccessibility = !WindowStacker.isTrusted
    @Published private(set) var renamingID: String?

    /// Called when renaming starts or ends, so the panel can take and give back the keyboard.
    var onRenamingChanged: ((Bool) -> Void)?
    /// Called while the grab bar is dragged, with the distance from where the drag started
    /// (AppKit points, y up). nil marks the start of a drag.
    var onDrag: ((CGSize?) -> Void)?

    /// Ghostty lists windows front to back, so keep our own first-seen order to stop
    /// the list from reshuffling every time you switch.
    private var order: [String] = []

    func refresh() {
        needsAccessibility = !WindowStacker.isTrusted
        guard Ghostty.runningApp != nil else {
            tabs = []
            selectedID = nil
            return
        }
        do {
            guard let state = try Ghostty.state() else {
                tabs = []
                selectedID = nil
                return
            }
            let ids = Set(state.tabs.map(\.id))
            order.removeAll { !ids.contains($0) }
            // Ghostty lists front to back, so the newest unseen window comes first; append oldest first.
            for tab in state.tabs.reversed() where !order.contains(tab.id) { order.append(tab.id) }
            // Ghostty can list a window twice while it is switching windows; keep the first.
            let byID = Dictionary(state.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let next = order.compactMap { byID[$0] }
            if next != tabs { tabs = next }
            if selectedID != state.frontWindowID { selectedID = state.frontWindowID }
            needsAutomation = false
        } catch GhosttyError.notAllowed {
            needsAutomation = true
        } catch {
            // Ghostty can be briefly unscriptable while windows open or close; try again next tick.
        }
    }

    func select(_ tab: GhosttyTab) {
        try? Ghostty.activate(windowID: tab.id)
        selectedID = tab.id
    }

    func close(_ tab: GhosttyTab) {
        try? Ghostty.close(windowID: tab.id)
        refresh()
    }

    func beginRename(_ tab: GhosttyTab) {
        renamingID = tab.id
        onRenamingChanged?(true)
    }

    func commitRename(_ tab: GhosttyTab, to title: String) {
        try? Ghostty.rename(windowID: tab.id, to: title.trimmingCharacters(in: .whitespaces))
        endRename()
        refresh()
    }

    func cancelRename() {
        endRename()
    }

    private func endRename() {
        guard renamingID != nil else { return }
        renamingID = nil
        onRenamingChanged?(false)
    }

    func newTab() {
        let directory = tabs.first { $0.id == selectedID }?.directory
        try? Ghostty.newWindow(directory: directory?.isEmpty == false ? directory : nil)
        refresh()
    }
}

struct SidebarView: View {
    @ObservedObject var model: TabsModel

    var body: some View {
        VStack(spacing: 0) {
            DragHandle(onDrag: { model.onDrag?($0) })
                .frame(height: 22)
                .overlay(
                    Capsule()
                        .fill(Color.secondary.opacity(0.45))
                        .frame(width: 36, height: 4)
                        .allowsHitTesting(false)
                )
                .help("Drag to move the terminal")
            if model.needsAutomation {
                Notice(
                    title: "Allow access to Ghostty",
                    text: "Turn on Ghostty under Ghostty Vertical Tabs in System Settings › Privacy & Security › Automation.",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                )
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                            TabRow(
                                tab: tab,
                                number: index + 1,
                                selected: tab.id == model.selectedID,
                                renaming: tab.id == model.renamingID,
                                onSelect: { model.select(tab) },
                                onClose: { model.close(tab) },
                                onRename: { model.beginRename(tab) },
                                onCommitRename: { model.commitRename(tab, to: $0) },
                                onCancelRename: { model.cancelRename() }
                            )
                        }
                    }
                    .padding(6)
                }
            }
            Spacer(minLength: 0)
            if model.needsAccessibility && !model.needsAutomation {
                Notice(
                    title: "Allow Accessibility",
                    text: "Needed to stack Ghostty's windows in one spot. Turn on Ghostty Vertical Tabs in System Settings › Privacy & Security › Accessibility.",
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                )
            }
            Divider()
            Button(action: model.newTab) {
                Label("New Tab", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct TabRow: View {
    let tab: GhosttyTab
    let number: Int
    let selected: Bool
    let renaming: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void
    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var folder: String {
        guard !tab.directory.isEmpty else { return "" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if tab.directory == home { return "~" }
        return (tab.directory as NSString).lastPathComponent
    }

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                if renaming {
                    TextField("Tab name", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .focused($fieldFocused)
                        .onSubmit { onCommitRename(draft) }
                        .onExitCommand(perform: onCancelRename)
                        .onAppear {
                            draft = tab.title
                            fieldFocused = true
                        }
                        .onChange(of: fieldFocused) { focused in
                            if !focused { onCancelRename() }
                        }
                } else {
                    Text(tab.title.isEmpty ? "Tab \(number)" : tab.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !folder.isEmpty, !tab.title.hasSuffix(folder) {
                    Text(folder)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if hovering || selected {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close tab")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.28) : (hovering ? Color.primary.opacity(0.07) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // The single tap fires right away, so switching never waits for a possible double click.
        .gesture(TapGesture(count: 2).onEnded { if !renaming { onRename() } })
        .simultaneousGesture(TapGesture().onEnded { if !renaming { onSelect() } })
        .help("\(tab.directory)\nDouble-click to rename")
    }
}

/// A strip that moves the terminal window when dragged. Ghostty's hidden title bar
/// can no longer be dragged, so this takes its place.
private struct DragHandle: NSViewRepresentable {
    let onDrag: (CGSize?) -> Void

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.onDrag = onDrag
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.onDrag = onDrag
    }

    final class HandleView: NSView {
        var onDrag: ((CGSize?) -> Void)?
        private var start: NSPoint?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            start = NSEvent.mouseLocation
            NSCursor.closedHand.push()
            onDrag?(nil)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let now = NSEvent.mouseLocation
            onDrag?(CGSize(width: now.x - start.x, height: now.y - start.y))
        }

        override func mouseUp(with event: NSEvent) {
            start = nil
            NSCursor.pop()
        }
    }
}

private struct Notice: View {
    let title: String
    let text: String
    let settingsURL: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") {
                if let url = URL(string: settingsURL) { NSWorkspace.shared.open(url) }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
