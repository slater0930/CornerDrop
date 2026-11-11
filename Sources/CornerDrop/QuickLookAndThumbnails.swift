import AppKit
import Quartz
import QuickLookThumbnailing

@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private(set) var url: URL?

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    func toggle(_ url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible && self.url == url {
            panel.orderOut(nil)
            return
        }
        self.url = url
        panel.dataSource = self
        panel.delegate = self
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { url == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { url as NSURL? }
    }
}

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    final class Thumb {
        let image: NSImage
        let isThumbnail: Bool
        init(image: NSImage, isThumbnail: Bool) {
            self.image = image
            self.isThumbnail = isThumbnail
        }
    }

    private let cache = NSCache<NSString, Thumb>()

    init() { cache.countLimit = 200 }

    func cached(_ item: FileItem) -> Thumb? {
        cache.object(forKey: item.cacheKey as NSString)
    }

    func load(_ item: FileItem) async -> Thumb? {
        let key = item.cacheKey as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 40, height: 40),
                                                   scale: scale, representationTypes: .all)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        let thumb = Thumb(image: rep.nsImage, isThumbnail: rep.type == .thumbnail)
        cache.setObject(thumb, forKey: key)
        return thumb
    }
}
