import Foundation
import Combine

enum ScreenCorner: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight

    var id: String { rawValue }
    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }

    var title: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
}

enum ClickAction: String, CaseIterable, Identifiable {
    case none, open, revealInFinder, quickLook, expandFolder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Do nothing"
        case .open: return "Open"
        case .revealInFinder: return "Reveal in Finder"
        case .quickLook: return "Quick Look"
        case .expandFolder: return "Expand folder"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var itemCount: Int { didSet { defaults.set(itemCount, forKey: "itemCount") } }
    @Published var corner: ScreenCorner { didSet { defaults.set(corner.rawValue, forKey: "corner") } }
    @Published var triggerDelay: Double { didSet { defaults.set(triggerDelay, forKey: "triggerDelay") } }

    @Published var peekEnabled: Bool { didSet { defaults.set(peekEnabled, forKey: "peekEnabled") } }
    @Published var peekDuration: Double { didSet { defaults.set(peekDuration, forKey: "peekDuration") } }

    @Published var singleClick: ClickAction { didSet { defaults.set(singleClick.rawValue, forKey: "singleClick") } }
    @Published var doubleClick: ClickAction { didSet { defaults.set(doubleClick.rawValue, forKey: "doubleClick") } }
    @Published var tripleClick: ClickAction { didSet { defaults.set(tripleClick.rawValue, forKey: "tripleClick") } }

    @Published var hideInProgress: Bool { didSet { defaults.set(hideInProgress, forKey: "hideInProgress") } }
    @Published var hideHidden: Bool { didSet { defaults.set(hideHidden, forKey: "hideHidden") } }
    @Published var hideFolders: Bool { didSet { defaults.set(hideFolders, forKey: "hideFolders") } }

    @Published var folderPath: String { didSet { defaults.set(folderPath, forKey: "folderPath") } }

    static var defaultFolderPath: String {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
            ?? (NSHomeDirectory() + "/Downloads")
    }

    var folderURL: URL {
        URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    var isDefaultFolder: Bool { folderURL.standardizedFileURL == URL(fileURLWithPath: Self.defaultFolderPath).standardizedFileURL }

    func action(forClickCount count: Int) -> ClickAction {
        switch count {
        case 1: return singleClick
        case 2: return doubleClick
        default: return tripleClick
        }
    }

    private init() {
        let d = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
        func double(_ key: String, _ fallback: Double) -> Double { d.object(forKey: key) as? Double ?? fallback }
        func action(_ key: String, _ fallback: ClickAction) -> ClickAction {
            d.string(forKey: key).flatMap(ClickAction.init(rawValue:)) ?? fallback
        }

        itemCount = min(max(d.object(forKey: "itemCount") as? Int ?? 5, 1), 20)
        corner = d.string(forKey: "corner").flatMap(ScreenCorner.init(rawValue:)) ?? .bottomLeft
        triggerDelay = double("triggerDelay", 0.15)
        peekEnabled = bool("peekEnabled", true)
        peekDuration = double("peekDuration", 4)
        singleClick = action("singleClick", .expandFolder)
        doubleClick = action("doubleClick", .open)
        tripleClick = action("tripleClick", .revealInFinder)
        hideInProgress = bool("hideInProgress", true)
        hideHidden = bool("hideHidden", true)
        hideFolders = bool("hideFolders", false)
        folderPath = d.string(forKey: "folderPath") ?? Self.defaultFolderPath
    }
}
