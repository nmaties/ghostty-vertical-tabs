import SwiftUI

enum DragPhase {
    case began
    /// Distance from where the drag started, in AppKit points (y up).
    case moved(CGSize)
    case ended
}

@MainActor
final class TabsModel: ObservableObject {
    @Published private(set) var tabs: [GhosttyTab] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var needsAutomation = false
    @Published var needsAccessibility = !WindowStacker.isTrusted
    /// Called while the grab bar is dragged.
    var onDrag: ((DragPhase) -> Void)?

    /// Ghostty lists windows front to back, so keep our own first-seen order to stop
    /// the list from reshuffling every time you switch.
    private var order: [String] = []

    private var refreshing = false

    /// Asks Ghostty for its windows in the background and publishes the result.
    func refresh() {
        needsAccessibility = !WindowStacker.isTrusted
        guard Ghostty.runningApp != nil else {
            tabs = []
            selectedID = nil
            return
        }
        guard !refreshing else { return }
        refreshing = true
        Ghostty.scriptQueue.async {
            let result = Result { try Ghostty.state() }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.refreshing = false
                    self.apply(result)
                }
            }
        }
    }

    private func apply(_ result: Result<GhosttyState?, Error>) {
        switch result {
        case .success(nil):
            tabs = []
            selectedID = nil
            needsAutomation = false
        case .success(let state?):
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
        case .failure(GhosttyError.notAllowed):
            needsAutomation = true
        case .failure:
            // Ghostty can be briefly unscriptable while windows open or close; try again next tick.
            break
        }
    }

    /// Runs a Ghostty command in the background, then refreshes the list.
    private func perform(_ command: @escaping @Sendable () throws -> Void) {
        Ghostty.scriptQueue.async {
            try? command()
            DispatchQueue.main.async { MainActor.assumeIsolated { self.refresh() } }
        }
    }

    func select(_ tab: GhosttyTab) {
        selectedID = tab.id
        let id = tab.id
        perform { try Ghostty.activate(windowID: id) }
    }

    func close(_ tab: GhosttyTab) {
        let id = tab.id
        perform { try Ghostty.close(windowID: id) }
    }

    func rename(_ tab: GhosttyTab) {
        selectedID = tab.id
        let id = tab.id
        perform { try Ghostty.promptRename(windowID: id) }
    }

    func newTab() {
        let directory = tabs.first { $0.id == selectedID }?.directory
        let dir = directory?.isEmpty == false ? directory : nil
        perform { try Ghostty.newWindow(directory: dir) }
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
                                onSelect: { model.select(tab) },
                                onClose: { model.close(tab) },
                                onRename: { model.rename(tab) }
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
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRename: () -> Void
    @State private var hovering = false

    private var folder: String {
        guard !tab.directory.isEmpty else { return "" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if tab.directory == home { return "~" }
        return (tab.directory as NSString).lastPathComponent
    }

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title.isEmpty ? "Tab \(number)" : tab.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
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
        .gesture(TapGesture(count: 2).onEnded(onRename))
        .simultaneousGesture(TapGesture().onEnded {
            if (NSApp.currentEvent?.clickCount ?? 1) < 2 { onSelect() }
        })
        .help("\(tab.directory)\nDouble-click to rename")
    }
}

/// A strip that moves the terminal window when dragged. Ghostty's hidden title bar
/// can no longer be dragged, so this takes its place.
private struct DragHandle: NSViewRepresentable {
    let onDrag: (DragPhase) -> Void

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.onDrag = onDrag
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.onDrag = onDrag
    }

    final class HandleView: NSView {
        var onDrag: ((DragPhase) -> Void)?
        private var start: NSPoint?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            start = NSEvent.mouseLocation
            NSCursor.closedHand.push()
            onDrag?(.began)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let now = NSEvent.mouseLocation
            onDrag?(.moved(CGSize(width: now.x - start.x, height: now.y - start.y)))
        }

        override func mouseUp(with event: NSEvent) {
            guard start != nil else { return }
            start = nil
            NSCursor.pop()
            onDrag?(.ended)
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
