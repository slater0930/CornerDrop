import AppKit
import SwiftUI
import Combine
import Quartz

enum Layout {
    static let width: CGFloat = 330
    static let rowHeight: CGFloat = 52
    static let padding: CGFloat = 6
    static let footerHeight: CGFloat = 28
    static let separator: CGFloat = 1
    static let cornerRadius: CGFloat = 14
    static let noteHeight: CGFloat = 28
    static let indent: CGFloat = 18
    static let screenMargin: CGFloat = 8
}

enum PanelMode { case hidden, peek, list }

/// State the SwiftUI content renders from.
@MainActor
final class PanelState: ObservableObject {
    @Published var mode: PanelMode = .hidden
    @Published var corner: ScreenCorner = .bottomLeft
    @Published var peekItem: FileItem?
    @Published var hoveredID: String?
    @Published var armedTrashID: String?
    @Published var expanded = false
    /// Paths of folders whose contents are shown inline.
    @Published var expandedFolders: Set<String> = []
    @Published var children: [String: [FileItem]] = [:]
    /// True when the list is taller than the screen and scrolls.
    @Published var scrolls = false
}

/// Borderless, non-activating floating panel. It can become key (for Space / Esc)
/// without activating the app, so the app you're working in stays frontmost.
final class CornerPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }

    // Quick Look panel control via the responder chain.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = QuickLookController.shared
        panel.delegate = QuickLookController.shared
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class PanelController: NSObject {
    let store: FileStore
    let settings = AppSettings.shared
    let state = PanelState()

    var isDragging = false

    private let panel = CornerPanel()
    private var timer: Timer?
    private var mode: PanelMode = .hidden
    private var cornerSince: Date?
    private var lastInside = Date()
    private var peekDeadline: Date?
    private var anchorScreen: NSScreen?
    private var manualShow = false
    private var hasEnteredSinceShow = false
    private var menuDepth = 0
    private var hideGeneration = 0
    private var pendingClick: DispatchWorkItem?
    private var qlWasVisible = false
    private var appToRestore: NSRunningApplication?
    private var hoveredItem: FileItem?
    private var instantToggle: (id: String, clicks: Int)?
    private var cancellables = Set<AnyCancellable>()
    private var globalClickMonitor: Any?

    init(store: FileStore) {
        self.store = store
        super.init()
        buildPanel()

        store.onNewFile = { [weak self] item in self?.peek(item) }
        store.onReload = { [weak self] in self?.refreshChildren() }

        store.$items
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.itemsChanged() } }
            .store(in: &cancellables)

        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.settingsChanged() } }
            .store(in: &cancellables)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(menuBegan), name: NSMenu.didBeginTrackingNotification, object: nil)
        nc.addObserver(self, selector: #selector(menuEnded), name: NSMenu.didEndTrackingNotification, object: nil)
        nc.addObserver(self, selector: #selector(screensChanged),
                       name: NSApplication.didChangeScreenParametersNotification, object: nil)

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.mode != .hidden, !self.isDragging else { return }
                self.hide()
            }
        }

        let timer = Timer(timeInterval: 0.05, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func buildPanel() {
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: Layout.cornerRadius)

        let root = RootView(state: state, store: store, settings: settings, controller: self)
        let host = FirstMouseHostingView(rootView: root)
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)

        panel.contentView = effect
        host.frame = effect.bounds
        panel.keyHandler = { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) ?? false }
        }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: Trigger loop

    @objc private func tick() {
        let p = NSEvent.mouseLocation
        let now = Date()
        let buttonsDown = NSEvent.pressedMouseButtons != 0
        let insidePanel = mode != .hidden && panel.frame.insetBy(dx: -1, dy: -1).contains(p)
        let qlVisible = QuickLookController.shared.isVisible

        // Give focus back to the previous app once Quick Look closes.
        if qlWasVisible && !qlVisible, let app = appToRestore {
            if NSApp.isActive && !NSApp.windows.contains(where: { $0.isVisible && $0.title == SettingsWindowController.title }) {
                app.activate()
            }
            appToRestore = nil
        }
        qlWasVisible = qlVisible

        switch mode {
        case .hidden, .peek:
            if mode == .peek && insidePanel && !buttonsDown {
                expandPeek()
                return
            }
            if let screen = cornerScreen(at: p), !buttonsDown {
                if cornerSince == nil { cornerSince = now }
                if let since = cornerSince, now.timeIntervalSince(since) >= settings.triggerDelay {
                    cornerSince = nil
                    showList(on: screen, manual: false)
                    return
                }
            } else {
                cornerSince = nil
            }
            if mode == .peek, let deadline = peekDeadline, now > deadline, !insidePanel {
                hide()
            }

        case .list:
            if insidePanel {
                hasEnteredSinceShow = true
                if !panel.isKeyWindow && !qlVisible { panel.makeKey() }
            }
            let keep = keepAliveRegion().contains(p)
                || isDragging
                || menuDepth > 0
                || qlVisible
                || (manualShow && !hasEnteredSinceShow)
            if keep {
                lastInside = now
            } else if now.timeIntervalSince(lastInside) > 0.35 {
                hide()
            }
        }
    }

    private func cornerScreen(at p: NSPoint) -> NSScreen? {
        let corner = settings.corner
        let t: CGFloat = 3
        for screen in NSScreen.screens {
            let f = screen.frame
            guard p.x >= f.minX - 1, p.x <= f.maxX + 1, p.y >= f.minY - 1, p.y <= f.maxY + 1 else { continue }
            let xOK = corner.isLeft ? p.x <= f.minX + t : p.x >= f.maxX - 1 - t
            let yOK = corner.isTop ? p.y >= f.maxY - 1 - t : p.y <= f.minY + t
            if xOK && yOK { return screen }
        }
        return nil
    }

    /// The panel plus the space between it and the screen corner.
    private func keepAliveRegion() -> NSRect {
        guard let screen = anchorScreen else { return panel.frame }
        let f = screen.frame
        let corner = state.corner
        let cornerPoint = NSRect(x: corner.isLeft ? f.minX : f.maxX - 1,
                                 y: corner.isTop ? f.maxY - 1 : f.minY,
                                 width: 1, height: 1)
        return panel.frame.union(cornerPoint).insetBy(dx: -4, dy: -4)
    }

    private func screenWithMouse() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main
    }

    // MARK: Showing / hiding

    func showManually() {
        guard let screen = screenWithMouse() else { return }
        showList(on: screen, manual: true)
    }

    private func showList(on screen: NSScreen, manual: Bool) {
        let fromHidden = mode == .hidden || !panel.isVisible
        manualShow = manual
        hasEnteredSinceShow = false
        peekDeadline = nil
        anchorScreen = screen
        state.corner = settings.corner
        state.peekItem = nil
        if fromHidden { state.expanded = false }
        mode = .list
        state.mode = .list
        lastInside = Date()
        present(fromHidden: fromHidden)
    }

    private func peek(_ item: FileItem) {
        guard settings.peekEnabled, mode != .list, let screen = screenWithMouse() else { return }
        let fromHidden = mode == .hidden || !panel.isVisible
        anchorScreen = screen
        state.corner = settings.corner
        state.peekItem = item
        mode = .peek
        state.mode = .peek
        peekDeadline = Date().addingTimeInterval(settings.peekDuration)
        present(fromHidden: fromHidden)
    }

    private func expandPeek() {
        mode = .list
        state.mode = .list
        state.peekItem = nil
        state.expanded = false
        manualShow = false
        hasEnteredSinceShow = true
        lastInside = Date()
        present(fromHidden: false)
    }

    private func contentHeight() -> CGFloat {
        switch mode {
        case .peek:
            return Layout.padding * 2 + Layout.rowHeight
        case .list, .hidden:
            let top = Array(store.items.prefix(visibleCount))
            let rows = DisplayRow.build(top: top, expanded: state.expandedFolders,
                                        children: state.children, newestFirst: true)
            let rowsHeight = rows.isEmpty ? Layout.rowHeight : rows.reduce(0) { $0 + $1.height }
            let chrome = Layout.padding * 2 + Layout.footerHeight + Layout.separator
            let screen = anchorScreen ?? NSScreen.main ?? NSScreen.screens[0]
            let maxHeight = screen.visibleFrame.height - Layout.screenMargin * 2
            let scrolls = chrome + rowsHeight > maxHeight
            if state.scrolls != scrolls { state.scrolls = scrolls }
            return min(chrome + rowsHeight, maxHeight)
        }
    }

    private func targetFrame() -> NSRect {
        let screen = anchorScreen ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let size = NSSize(width: Layout.width, height: contentHeight())
        let corner = state.corner
        let x = corner.isLeft ? vf.minX + Layout.screenMargin : vf.maxX - Layout.screenMargin - size.width
        let y = corner.isTop ? vf.maxY - Layout.screenMargin - size.height : vf.minY + Layout.screenMargin
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    private func present(fromHidden: Bool) {
        hideGeneration += 1
        let target = targetFrame()
        if fromHidden {
            var start = target
            start.origin.x += state.corner.isLeft ? -8 : 8
            start.origin.y += state.corner.isTop ? 8 : -8
            panel.alphaValue = 0
            panel.setFrame(start, display: true)
            panel.orderFrontRegardless()
        } else if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = fromHidden ? 0.18 : 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.panel.invalidateShadow() }
        }
    }

    func hide() {
        guard mode != .hidden else { return }
        mode = .hidden
        cornerSince = nil
        peekDeadline = nil
        pendingClick?.cancel()
        hideGeneration += 1
        let generation = hideGeneration
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.hideGeneration else { return }
                self.panel.orderOut(nil)
                self.state.mode = .hidden
                self.state.peekItem = nil
                self.state.hoveredID = nil
                self.state.armedTrashID = nil
                self.state.expanded = false
                self.state.expandedFolders = []
                self.state.children = [:]
                self.state.scrolls = false
                self.hoveredItem = nil
            }
        }
    }

    private func itemsChanged() {
        switch mode {
        case .hidden: break
        case .list: present(fromHidden: false)
        case .peek:
            if let item = state.peekItem, !store.items.contains(where: { $0.id == item.id }) { hide() }
        }
    }

    private func settingsChanged() {
        if mode != .hidden {
            if state.corner != settings.corner { hide() } else { present(fromHidden: false) }
        }
    }

    @objc private func menuBegan() { menuDepth += 1 }
    @objc private func menuEnded() { menuDepth = max(0, menuDepth - 1) }
    @objc private func screensChanged() { hide() }

    // MARK: Row interaction

    /// Rows shown in the list: the configured count, doubled while expanded.
    var visibleCount: Int {
        state.expanded ? settings.itemCount * 2 : settings.itemCount
    }

    func setExpanded(_ expanded: Bool) {
        guard mode == .list, state.expanded != expanded else { return }
        state.expanded = expanded
        present(fromHidden: false)
    }

    func setHover(_ item: FileItem, inside: Bool) {
        if inside {
            hoveredItem = item
            if state.hoveredID != item.id { state.hoveredID = item.id }
        } else {
            if hoveredItem?.id == item.id { hoveredItem = nil }
            if state.hoveredID == item.id { state.hoveredID = nil }
            if state.armedTrashID == item.id { state.armedTrashID = nil }
        }
    }

    // MARK: Folders

    func toggleFolder(_ item: FileItem) {
        guard item.isDirectory, mode == .list else { return }
        if state.expandedFolders.contains(item.id) {
            // Collapse it and anything opened inside it.
            state.expandedFolders = state.expandedFolders.filter { $0 != item.id && !$0.hasPrefix(item.id + "/") }
        } else {
            state.children[item.id] = store.children(of: item) ?? []
            state.expandedFolders.insert(item.id)
        }
        present(fromHidden: false)
    }

    /// Re-reads expanded folders after any change on disk.
    private func refreshChildren() {
        guard !state.expandedFolders.isEmpty else { return }
        var children: [String: [FileItem]] = [:]
        var expanded = state.expandedFolders
        for path in state.expandedFolders {
            let folder = FileItem(url: URL(fileURLWithPath: path, isDirectory: true), date: .distantPast,
                                  isDirectory: true, isInProgress: false)
            if let kids = store.children(of: folder) {
                children[path] = kids
            } else {
                expanded.remove(path)
            }
        }
        if children != state.children { state.children = children }
        if expanded != state.expandedFolders { state.expandedFolders = expanded }
        if mode == .list { present(fromHidden: false) }
    }

    func revealContents(of folder: FileItem) {
        NSWorkspace.shared.open(folder.url)
        hide()
    }

    func handleClick(_ item: FileItem, count: Int) {
        pendingClick?.cancel()
        let clicks = min(max(count, 1), 3)
        let action = settings.action(forClickCount: clicks)

        // Expanding a folder happens instantly (like Finder's disclosure), without
        // waiting to see whether a double-click follows. If one does, undo it first.
        if action == .expandFolder {
            if item.isDirectory {
                toggleFolder(item)
                instantToggle = (item.id, clicks)
            }
            return
        }
        if let toggle = instantToggle, toggle.id == item.id, toggle.clicks < clicks {
            toggleFolder(item)
        }
        instantToggle = nil

        let laterConfigured = clicks < 3 && ((clicks + 1)...3).contains { settings.action(forClickCount: $0) != .none }
        if laterConfigured {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.perform(action, on: item) }
            }
            pendingClick = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
        } else {
            perform(action, on: item)
        }
    }

    func perform(_ action: ClickAction, on item: FileItem) {
        switch action {
        case .none:
            break
        case .expandFolder:
            toggleFolder(item)
        case .open:
            NSWorkspace.shared.open(item.url)
            hide()
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
            hide()
        case .quickLook:
            toggleQuickLook(item)
        }
    }

    func toggleQuickLook(_ item: FileItem) {
        // Quick Look's panel only shows for an active app, so activate briefly
        // and hand focus back when it closes.
        if !NSApp.isActive {
            appToRestore = NSWorkspace.shared.frontmostApplication
            NSApp.activate(ignoringOtherApps: true)
        }
        panel.makeKey()
        QuickLookController.shared.toggle(item.url)
    }

    func trash(_ item: FileItem) {
        state.armedTrashID = nil
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        } catch {
            NSSound.beep()
        }
        store.scheduleReload(delay: 0.05)
    }

    func copy(_ item: FileItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item.url as NSURL])
    }

    func openFolder() {
        NSWorkspace.shared.open(settings.folderURL)
        hide()
    }

    func openSettings() {
        hide()
        (NSApp.delegate as? AppDelegate)?.openSettings()
    }

    func dragImage(for item: FileItem) -> NSImage {
        let source = ThumbnailCache.shared.cached(item)?.image ?? NSWorkspace.shared.icon(forFile: item.url.path)
        let image = NSImage(size: NSSize(width: 48, height: 48), flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        return image
    }

    func contextMenu(for item: FileItem) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem("Open") { [weak self] in self?.perform(.open, on: item) })
        menu.addItem(openWithItem(for: item))
        if item.isDirectory && mode == .list {
            let title = state.expandedFolders.contains(item.id) ? "Hide Contents" : "Show Contents"
            menu.addItem(ClosureMenuItem(title) { [weak self] in self?.toggleFolder(item) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Reveal in Finder") { [weak self] in self?.perform(.revealInFinder, on: item) })
        menu.addItem(ClosureMenuItem("Quick Look") { [weak self] in self?.toggleQuickLook(item) })
        menu.addItem(ClosureMenuItem("Copy") { [weak self] in self?.copy(item) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Move to Trash") { [weak self] in self?.trash(item) })
        return menu
    }

    private func openWithItem(for item: FileItem) -> NSMenuItem {
        let parent = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let workspace = NSWorkspace.shared
        let defaultApp = workspace.urlForApplication(toOpen: item.url)
        var apps = workspace.urlsForApplications(toOpen: item.url)
        if let defaultApp {
            apps.removeAll { $0 == defaultApp }
            apps.insert(defaultApp, at: 0)
        }
        for appURL in apps.prefix(20) {
            var name = FileManager.default.displayName(atPath: appURL.path)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            if appURL == defaultApp { name += " (default)" }
            let mi = ClosureMenuItem(name) { [weak self] in
                workspace.open([item.url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
                self?.hide()
            }
            let icon = workspace.icon(forFile: appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            mi.image = icon
            sub.addItem(mi)
            if appURL == defaultApp && apps.count > 1 { sub.addItem(.separator()) }
        }
        if apps.isEmpty {
            let none = NSMenuItem(title: "No Apps", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        }
        parent.submenu = sub
        return parent
    }

    // MARK: Keyboard

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 49: // Space
            if let item = hoveredItem ?? (mode == .peek ? state.peekItem : nil) {
                toggleQuickLook(item)
                return true
            }
            return false
        case 53: // Esc
            hide()
            return true
        default:
            return false
        }
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { MainActor.assumeIsolated { handler() } }
}
