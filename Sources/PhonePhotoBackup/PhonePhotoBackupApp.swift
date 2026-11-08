import AppKit
import SwiftUI

@main
struct PhonePhotoBackupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = BackupModel()
    @State private var updater = Updater()

    var body: some Scene {
        Window("Phone Photo Backup", id: "main") {
            ContentView()
                .environment(model)
                .environment(updater)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.check(userInitiated: true) }
                Toggle("Check for Updates Automatically", isOn: $updater.checksAutomatically)
            }
            CommandGroup(replacing: .newItem) {
                Button("Choose Source Folder…") { model.chooseSource() }
                    .keyboardShortcut("o")
                    .disabled(model.isBusy)
                Button("Choose Backup Location…") { model.chooseDestination() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.isBusy)
            }
            CommandMenu("Backup") {
                Button("Scan Source") { model.scan() }
                    .keyboardShortcut("r")
                    .disabled(!model.canScan)
                Button("Start Backup") { model.requestStart() }
                    .keyboardShortcut("b")
                    .disabled(!model.canStart)
                Button("Import This Phone into Photos (No Backup)…") { model.importPhoneDirectly() }
                    .disabled(!model.canImportPhone)
                Button("Import All Backups into Photos…") { model.importAllBackups() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(!model.canImport)
                OpenBackupVideosButton(title: "Browse Backup Videos…")
                    .environment(model)
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Button("Stop") { model.cancel() }
                    .keyboardShortcut(".")
                    .disabled(!model.isBusy)
                Divider()
                Button("Show Backup Folder in Finder") { model.revealBackupFolder() }
                    .disabled(model.plan == nil && model.report == nil)
            }
        }

        Window("Backup Videos", id: BackupVideosView.windowID) {
            BackupVideosView()
                .environment(model)
        }
        .defaultSize(width: 1100, height: 720)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched via `swift run` (no .app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
