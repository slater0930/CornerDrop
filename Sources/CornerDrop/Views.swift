import SwiftUI
import AppKit

struct RootView: View {
    @ObservedObject var state: PanelState
    @ObservedObject var store: FileStore
    @ObservedObject var settings: AppSettings
    let controller: PanelController

    private var visible: [FileItem] { Array(store.items.prefix(controller.visibleCount)) }
    private var canExpand: Bool { store.items.count > settings.itemCount }

    var body: some View {
        let isTop = state.corner.isTop
        VStack(spacing: 0) {
            if state.mode == .peek, let item = state.peekItem {
                FileRow(item: item, state: state, controller: controller)
            } else {
                // Newest file sits closest to the corner; the footer is on the far edge.
                if !isTop { footer; separator }
                rows(newestFirst: isTop)
                if isTop { separator; footer }
            }
        }
        .padding(Layout.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isTop ? .top : .bottom)
        .overlay(
            RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func rows(newestFirst: Bool) -> some View {
        let rows = DisplayRow.build(top: visible, expanded: state.expandedFolders,
                                    children: state.children, newestFirst: newestFirst)
        if rows.isEmpty {
            Text("No recent files")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: Layout.rowHeight)
        } else if state.scrolls {
            ScrollView {
                VStack(spacing: 0) { rowViews(rows) }
            }
            .defaultScrollAnchor(newestFirst ? .top : .bottom)
        } else {
            rowViews(rows)
        }
    }

    @ViewBuilder
    private func rowViews(_ rows: [DisplayRow]) -> some View {
        ForEach(rows) { row in
            switch row {
            case let .file(item, depth):
                FileRow(item: item, depth: depth, state: state, controller: controller)
            case let .note(folder, text, depth):
                NoteRow(text: text, depth: depth) { controller.revealContents(of: folder) }
            }
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: Layout.separator)
            .padding(.horizontal, 8)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                controller.openFolder()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                    Text(settings.folderURL.lastPathComponent)
                        .lineLimit(1)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open folder in Finder")

            Spacer()

            if canExpand {
                ExpandArrow(
                    expanded: state.expanded,
                    pointsUp: !state.corner.isTop,
                    onHover: { controller.setExpanded(true) },
                    onClick: { controller.setExpanded(!state.expanded) }
                )
            }

            Spacer()

            Button {
                controller.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 10)
        .frame(height: Layout.footerHeight)
    }
}

/// Arrow in the header: hovering expands the list, clicking toggles it.
struct ExpandArrow: View {
    let expanded: Bool
    let pointsUp: Bool
    let onHover: () -> Void
    let onClick: () -> Void
    @State private var hovering = false

    var body: some View {
        // Points away from the corner (the direction the list grows); flips once expanded.
        let up = expanded ? !pointsUp : pointsUp
        Image(systemName: up ? "chevron.up" : "chevron.down")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 34, height: 20)
            .background(
                Capsule().fill(Color.primary.opacity(hovering ? 0.12 : 0))
            )
            .overlay(
                HoverClickArea(
                    onHover: { inside in
                        hovering = inside
                        if inside && !expanded { onHover() }
                    },
                    onClick: onClick
                )
            )
            .help(expanded ? "Show fewer" : "Show more")
    }
}

/// Hover + click detection that works while the app is in the background
/// (SwiftUI's onHover only fires for the active app).
struct HoverClickArea: NSViewRepresentable {
    let onHover: (Bool) -> Void
    let onClick: () -> Void

    func makeNSView(context: Context) -> HoverClickNSView {
        let view = HoverClickNSView()
        view.onHover = onHover
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: HoverClickNSView, context: Context) {
        view.onHover = onHover
        view.onClick = onClick
    }
}

final class HoverClickNSView: NSView {
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// One line in the list: a file/folder at some nesting depth, or a note under an expanded folder.
enum DisplayRow: Identifiable {
    case file(FileItem, depth: Int)
    case note(folder: FileItem, text: String, depth: Int)

    static let childLimit = 15

    var id: String {
        switch self {
        case let .file(item, _): return item.id
        case let .note(folder, _, _): return folder.id + "#note"
        }
    }

    var height: CGFloat {
        switch self {
        case .file: return Layout.rowHeight
        case .note: return Layout.noteHeight
        }
    }

    /// Flattens the top-level items plus the contents of expanded folders.
    /// For bottom corners the whole list is reversed, so the newest item and an
    /// expanded folder's own row stay put while its contents open away from the corner.
    static func build(top: [FileItem], expanded: Set<String>, children: [String: [FileItem]],
                      newestFirst: Bool) -> [DisplayRow] {
        var rows: [DisplayRow] = []
        func add(_ item: FileItem, depth: Int) {
            rows.append(.file(item, depth: depth))
            guard item.isDirectory, expanded.contains(item.id), let kids = children[item.id] else { return }
            if kids.isEmpty {
                rows.append(.note(folder: item, text: "Empty folder", depth: depth + 1))
                return
            }
            for kid in kids.prefix(childLimit) { add(kid, depth: depth + 1) }
            if kids.count > childLimit {
                rows.append(.note(folder: item, text: "\(kids.count - childLimit) more – Show in Finder",
                                  depth: depth + 1))
            }
        }
        for item in top { add(item, depth: 0) }
        return newestFirst ? rows : rows.reversed()
    }
}

struct NoteRow: View {
    let text: String
    let depth: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(hovering ? .primary : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 8 + CGFloat(depth) * Layout.indent)
            .frame(height: Layout.noteHeight)
            .overlay(HoverClickArea(onHover: { hovering = $0 }, onClick: action))
    }
}

struct FileRow: View {
    let item: FileItem
    var depth: Int = 0
    @ObservedObject var state: PanelState
    let controller: PanelController

    var body: some View {
        let hovered = state.hoveredID == item.id
        let armed = state.armedTrashID == item.id
        let expanded = state.expandedFolders.contains(item.id)
        let folderWidth: CGFloat = item.isDirectory ? 26 : 0

        ZStack(alignment: .trailing) {
            HStack(spacing: 10) {
                ThumbnailView(item: item)
                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(text: item.name, active: hovered)
                        .font(.system(size: 13, weight: .medium))
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(RelativeTime.string(for: item.date, now: context.date))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Color.clear.frame(width: folderWidth + (hovered ? (armed ? 56 : 28) : 0), height: 1)
            }
            .padding(.leading, 8 + CGFloat(depth) * Layout.indent)
            .padding(.trailing, 8)

            // AppKit view on top handles hover, clicks, right-click and dragging.
            RowInteractionView(item: item, controller: controller)

            HStack(spacing: 6) {
                if hovered {
                    TrashControl(
                        armed: armed,
                        onArm: { state.armedTrashID = item.id },
                        onCancel: { state.armedTrashID = nil },
                        onConfirm: { controller.trash(item) }
                    )
                }
                if item.isDirectory {
                    DisclosureButton(expanded: expanded, opensUp: !state.corner.isTop) {
                        controller.toggleFolder(item)
                    }
                }
            }
            .padding(.trailing, 10)
        }
        .frame(height: Layout.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovered ? 0.09 : 0))
        )
    }
}

/// Chevron on folder rows: points right when collapsed, toward the contents when open.
struct DisclosureButton: View {
    let expanded: Bool
    let opensUp: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(expanded ? (opensUp ? -90 : 90) : 0))
            .animation(.easeOut(duration: 0.15), value: expanded)
            .frame(width: 20, height: 20)
            .background(Circle().fill(Color.primary.opacity(hovering ? 0.12 : 0)))
            .overlay(HoverClickArea(onHover: { hovering = $0 }, onClick: action))
            .help(expanded ? "Collapse folder" : "Show folder contents")
    }
}

/// X → (X, ✓). The file only goes to the Trash when the tick is clicked.
struct TrashControl: View {
    let armed: Bool
    let onArm: () -> Void
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if armed {
                CircleButton(symbol: "xmark", help: "Cancel", action: onCancel)
                CircleButton(symbol: "checkmark", help: "Move to Trash", destructive: true, action: onConfirm)
            } else {
                CircleButton(symbol: "xmark", help: "Move to Trash…", action: onArm)
            }
        }
        .animation(.easeOut(duration: 0.12), value: armed)
    }
}

struct CircleButton: View {
    let symbol: String
    let help: String
    var destructive = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(destructive ? Color.white : Color.primary.opacity(0.75))
                .frame(width: 20, height: 20)
                .background(
                    Circle().fill(destructive
                                  ? Color.red.opacity(hovering ? 1 : 0.85)
                                  : Color.primary.opacity(hovering ? 0.2 : 0.12))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Single-line text that truncates normally and scrolls when hovered and too long.
struct MarqueeText: View {
    let text: String
    let active: Bool

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var overflow: CGFloat { max(0, textWidth - containerWidth) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                if active && overflow > 0 {
                    Text(text)
                        .lineLimit(1)
                        .fixedSize()
                        .offset(x: offset)
                } else {
                    Text(text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .clipped()
            .onAppear { containerWidth = geo.size.width }
            .onChange(of: geo.size.width) { _, width in containerWidth = width }
        }
        .frame(height: 17)
        .background(
            Text(text)
                .lineLimit(1)
                .fixedSize()
                .hidden()
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { textWidth = g.size.width }
                        .onChange(of: g.size.width) { _, width in textWidth = width }
                }),
            alignment: .leading
        )
        .task(id: active) {
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { offset = 0 }
            guard active else { return }
            try? await Task.sleep(for: .milliseconds(450))
            while !Task.isCancelled {
                let distance = overflow + 6
                guard overflow > 0 else { return }
                let duration = Double(distance) / 35.0
                withAnimation(.linear(duration: duration)) { offset = -distance }
                try? await Task.sleep(for: .seconds(duration + 1.0))
                if Task.isCancelled { break }
                withAnimation(.easeInOut(duration: 0.35)) { offset = 0 }
                try? await Task.sleep(for: .seconds(1.4))
            }
        }
    }
}

struct ThumbnailView: View {
    let item: FileItem
    @State private var thumb: ThumbnailCache.Thumb?

    var body: some View {
        ZStack {
            if let thumb, thumb.isThumbnail {
                Image(nsImage: thumb.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
            } else {
                Image(nsImage: thumb?.image ?? NSWorkspace.shared.icon(forFile: item.url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)
            }
        }
        .frame(width: 40, height: 40)
        .task(id: item.cacheKey) {
            if let cached = ThumbnailCache.shared.cached(item) {
                thumb = cached
            } else {
                thumb = nil
                thumb = await ThumbnailCache.shared.load(item)
            }
        }
    }
}

enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    static func string(for date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "Just now" }
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
