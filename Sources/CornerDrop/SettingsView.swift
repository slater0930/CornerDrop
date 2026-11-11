import SwiftUI
import AppKit
import ServiceManagement

@MainActor
final class SettingsWindowController {
    static let title = "Corner Drop Settings"
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(settings: .shared))
            let window = NSWindow(contentViewController: hosting)
            window.title = Self.title
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var updater = Updater.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginMessage: String?

    var body: some View {
        Form {
            Section("Trigger") {
                Picker("Screen corner", selection: $settings.corner) {
                    ForEach(ScreenCorner.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Hover delay") {
                    HStack {
                        Slider(value: $settings.triggerDelay, in: 0...1, step: 0.05)
                        Text(String(format: "%.2fs", settings.triggerDelay))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("Turn off any macOS Hot Corner on the same corner so they don't conflict.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Hot Corners…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            }

            Section("List") {
                Stepper(value: $settings.itemCount, in: 1...20) {
                    LabeledContent("Files to show", value: "\(settings.itemCount)")
                }
            }

            Section {
                Picker("Single click", selection: $settings.singleClick) { actionOptions }
                Picker("Double click", selection: $settings.doubleClick) { actionOptions }
                Picker("Triple click", selection: $settings.tripleClick) { actionOptions }
            } header: {
                Text("Clicking a file")
            } footer: {
                Text("Expand folder only affects folders (files ignore it); the chevron on a folder always expands it too. Hover a file and press Space for Quick Look. Right-click for more options. Drag a file into any app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("New files") {
                Toggle("Peek when a new file arrives", isOn: $settings.peekEnabled)
                LabeledContent("Peek stays for") {
                    HStack {
                        Slider(value: $settings.peekDuration, in: 2...10, step: 1)
                        Text("\(Int(settings.peekDuration))s")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(!settings.peekEnabled)
            }

            Section("Folder") {
                LabeledContent("Watching") {
                    Text((settings.folderURL.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Use Downloads") { settings.folderPath = AppSettings.defaultFolderPath }
                        .disabled(settings.isDefaultFolder)
                    Button("Choose…", action: chooseFolder)
                }
            }

            Section("Filters") {
                Toggle(isOn: $settings.hideInProgress) {
                    Text("Hide in-progress downloads")
                    Text(".crdownload, .download, .part and similar")
                }
                Toggle("Hide hidden files", isOn: $settings.hideHidden)
                Toggle("Hide folders", isOn: $settings.hideFolders)
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let loginMessage {
                    Text(loginMessage).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
                Toggle("Download and install updates automatically", isOn: $updater.automaticallyDownloads)
                    .disabled(!updater.automaticallyChecks)
                HStack {
                    Text("Version \(appVersion)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 700)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    @ViewBuilder
    private var actionOptions: some View {
        ForEach(ClickAction.allCases) { Text($0.title).tag($0) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.folderURL
        panel.prompt = "Watch Folder"
        if panel.runModal() == .OK, let url = panel.url {
            settings.folderPath = url.path
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginMessage = nil
        } catch {
            loginMessage = "Couldn't change login item: \(error.localizedDescription)"
        }
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        if status == .requiresApproval {
            loginMessage = "Approve Corner Drop in System Settings › General › Login Items."
        }
    }
}
