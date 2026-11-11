import AppKit
import SwiftUI

/// Transparent AppKit layer over each row: hover tracking (works while the app is
/// in the background), click counting, right-click menu and a real file drag that
/// other apps treat exactly like a drag from Finder.
struct RowInteractionView: NSViewRepresentable {
    let item: FileItem
    let controller: PanelController

    func makeNSView(context: Context) -> RowInteractionNSView {
        let view = RowInteractionNSView()
        view.item = item
        view.controller = controller
        return view
    }

    func updateNSView(_ view: RowInteractionNSView, context: Context) {
        view.item = item
        view.controller = controller
    }
}

final class RowInteractionNSView: NSView, NSDraggingSource {
    var item: FileItem?
    weak var controller: PanelController?

    private var downEvent: NSEvent?
    private var dragStarted = false
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

    override func mouseEntered(with event: NSEvent) {
        guard let item else { return }
        controller?.setHover(item, inside: true)
    }

    override func mouseExited(with event: NSEvent) {
        guard let item else { return }
        controller?.setHover(item, inside: false)
    }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted, let down = downEvent, let item, let controller else { return }
        let a = down.locationInWindow
        let b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 4 else { return }
        dragStarted = true

        let draggingItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
        let start = convert(a, from: nil)
        draggingItem.setDraggingFrame(NSRect(x: start.x - 24, y: start.y - 24, width: 48, height: 48),
                                      contents: controller.dragImage(for: item))
        controller.isDragging = true
        let session = beginDraggingSession(with: [draggingItem], event: down, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { downEvent = nil }
        guard !dragStarted, let item else { return }
        controller?.handleClick(item, count: event.clickCount)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let item, let controller else { return }
        NSMenu.popUpContextMenu(controller.contextMenu(for: item), with: event, for: self)
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragStarted = false
        controller?.isDragging = false
    }
}
