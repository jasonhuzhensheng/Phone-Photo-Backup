import AppKit
import SwiftUI

/// The interface language chosen in the app menu. macOS picks the language when the app starts,
/// so a change is saved as this app's `AppleLanguages` and applied after a restart.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english = "en", chinese = "zh-Hans"

    var id: String { rawValue }
    static let key = "appLanguage"

    static var saved: AppLanguage {
        UserDefaults.standard.string(forKey: key).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    /// Saves the choice; only this app's settings change, not the system's language order.
    static func save(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        defaults.set(language.rawValue, forKey: key)
        if language == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
    }
}

/// "Language" submenu in the app menu.
struct LanguageMenu: View {
    let model: BackupModel
    @State private var language = AppLanguage.saved

    var body: some View {
        Picker("Language", selection: $language) {
            Text("Follow System").tag(AppLanguage.system)
            Text(verbatim: "English").tag(AppLanguage.english)
            Text(verbatim: "简体中文").tag(AppLanguage.chinese)
        }
        .onChange(of: language) { _, new in
            AppLanguage.save(new)
            askToRestart()
        }
    }

    private func askToRestart() {
        let alert = NSAlert()
        alert.messageText = String(localized: "The new language is used after Phone Photo Backup restarts.")
        let canRestart = Bundle.main.bundleURL.pathExtension == "app"
        if model.isBusy || !canRestart {
            alert.informativeText = model.isBusy
                ? String(localized: "Work in progress is not interrupted. The language changes the next time you open the app.")
                : String(localized: "The language changes the next time you open the app.")
            alert.addButton(withTitle: String(localized: "OK"))
            alert.runModal()
            return
        }
        alert.addButton(withTitle: String(localized: "Restart Now"))
        alert.addButton(withTitle: String(localized: "Later"))
        if alert.runModal() == .alertFirstButtonReturn { Self.restart() }
    }

    /// Opens the app again once this process has exited, then quits.
    private static func restart() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
                             "sh", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        guard (try? process.run()) != nil else { return }
        // An open sheet makes macOS refuse to quit; nothing is running (checked above).
        for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
    }
}
