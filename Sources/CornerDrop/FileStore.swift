import Foundation
import Combine
import CoreServices

struct FileItem: Identifiable, Equatable {
    let url: URL
    let date: Date
    let isDirectory: Bool
    let isInProgress: Bool

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var cacheKey: String { "\(url.path)|\(date.timeIntervalSince1970)" }
}

/// Watches a folder with FSEvents and keeps a sorted list of its most recent entries.
@MainActor
final class FileStore: ObservableObject {
    /// Filtered entries, newest first (capped so publishing stays cheap).
    @Published private(set) var items: [FileItem] = []

    /// Called with the newest file that appeared since the last scan.
    var onNewFile: ((FileItem) -> Void)?

    /// Called after every rescan (including changes inside subfolders).
    var onReload: (() -> Void)?

    /// Contents of a subfolder, newest first, using the hidden / in-progress filters.
    func children(of folder: FileItem) -> [FileItem]? {
        FileStore.scan(folder: folder.url, hideHidden: settings.hideHidden,
                       hideInProgress: settings.hideInProgress, hideFolders: false)
    }

    nonisolated static let inProgressExtensions: Set<String> = [
        "crdownload", "download", "part", "partial", "opdownload", "tmp"
    ]

    private let settings: AppSettings
    private let scanQueue = DispatchQueue(label: "com.slater0930.cornerdrop.scan", qos: .utility)
    private var knownPaths: Set<String>?
    private var stream: FSEventStreamRef?
    private var watchedPath: String?
    private var pendingReload: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private let maxItems = 40

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.settingsChanged() }
            }
            .store(in: &cancellables)
        restartWatcher()
        reload(announce: false)
    }

    /// Debounced rescan triggered by file system events.
    func scheduleReload(delay: TimeInterval = 0.25) {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reload(announce: true) }
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func settingsChanged() {
        if settings.folderURL.path != watchedPath {
            knownPaths = nil
            restartWatcher()
        }
        reload(announce: false)
    }

    private func reload(announce: Bool) {
        let folder = settings.folderURL
        let hideHidden = settings.hideHidden
        let hideInProgress = settings.hideInProgress
        let hideFolders = settings.hideFolders
        let limit = maxItems
        scanQueue.async { [weak self] in
            let result = FileStore.scan(folder: folder, hideHidden: hideHidden,
                                        hideInProgress: hideInProgress, hideFolders: hideFolders)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.apply(result, limit: limit, announce: announce)
                }
            }
        }
    }

    private func apply(_ result: [FileItem]?, limit: Int, announce: Bool) {
        guard let all = result else {
            // Folder unreadable (e.g. waiting on the Downloads permission prompt): retry.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                MainActor.assumeIsolated { self?.reload(announce: false) }
            }
            return
        }
        let paths = Set(all.map(\.id))
        if announce, let known = knownPaths {
            let cutoff = Date().addingTimeInterval(-120)
            let fresh = all.filter { !known.contains($0.id) && !$0.isInProgress && $0.date > cutoff }
            if let newest = fresh.first {
                // Publish the list first so the peek and list agree.
                let trimmed = Array(all.prefix(limit))
                if trimmed != items { items = trimmed }
                knownPaths = paths
                onNewFile?(newest)
                onReload?()
                return
            }
        }
        knownPaths = paths
        let trimmed = Array(all.prefix(limit))
        if trimmed != items { items = trimmed }
        onReload?()
    }

    nonisolated static func scan(folder: URL, hideHidden: Bool, hideInProgress: Bool, hideFolders: Bool) -> [FileItem]? {
        let keys: [URLResourceKey] = [
            .addedToDirectoryDateKey, .contentModificationDateKey, .creationDateKey,
            .isDirectoryKey, .isPackageKey
        ]
        let options: FileManager.DirectoryEnumerationOptions = hideHidden ? [.skipsHiddenFiles] : []
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: options) else { return nil }

        var out: [FileItem] = []
        out.reserveCapacity(urls.count)
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDir = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
            let inProgress = inProgressExtensions.contains(url.pathExtension.lowercased())
            if hideInProgress && inProgress { continue }
            if hideFolders && isDir { continue }
            let added = values?.addedToDirectoryDate ?? values?.creationDate ?? .distantPast
            let modified = values?.contentModificationDate ?? .distantPast
            out.append(FileItem(url: url, date: max(added, modified), isDirectory: isDir, isInProgress: inProgress))
        }
        out.sort { $0.date > $1.date }
        return out
    }

    // MARK: FSEvents

    private func restartWatcher() {
        stopWatcher()
        let path = settings.folderURL.path
        watchedPath = path

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let store = Unmanaged<FileStore>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { store.scheduleReload() }
        }

        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func stopWatcher() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
