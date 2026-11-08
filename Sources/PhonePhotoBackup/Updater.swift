import AppKit
import BackupCore
import Observation
import SwiftUI

/// Checks GitHub Releases for a newer version and, when the user agrees, downloads it, verifies it
/// (SHA-256, bundle identifier, version, code signature), swaps it into place and relaunches.
/// Nothing is installed without the user clicking "Install and Restart".
@MainActor @Observable
final class Updater {
    enum State {
        case idle
        case checking
        case upToDate
        case available(AppUpdateOffer)
        case downloading(AppUpdateOffer, fraction: Double)
        case installing(AppUpdateOffer)
        case failed(String, offer: AppUpdateOffer?)
    }

    static let repository = "jasonhuzhensheng/Phone-Photo-Backup"
    private static let autoKey = "checkForUpdatesAutomatically", lastCheckKey = "lastUpdateCheck"
    private static let checkInterval: TimeInterval = 24 * 3600

    private(set) var state = State.idle
    /// True while the update window should be shown.
    var showingWindow = false
    var checksAutomatically: Bool {
        didSet { UserDefaults.standard.set(checksAutomatically, forKey: Self.autoKey) }
    }

    @ObservationIgnored private var task: Task<Void, Never>?

    init() {
        checksAutomatically = UserDefaults.standard.object(forKey: Self.autoKey) as? Bool ?? true
    }

    /// The version of this app, from Info.plist ("dev" when run without a bundle).
    static var currentVersionText: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var currentBuildText: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// Only a real app bundle can update itself; the developer self-check never does.
    private var canUpdate: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.bundleIdentifier != nil
            && ProcessInfo.processInfo.environment["PPB_SNAPSHOT_DIR"] == nil
    }

    /// Where to look for releases. `PPB_UPDATE_FEED` overrides it for testing with a local file.
    private var feedURL: URL {
        if let override = ProcessInfo.processInfo.environment["PPB_UPDATE_FEED"], let url = URL(string: override) {
            return url
        }
        return URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
    }

    var availableOffer: AppUpdateOffer? {
        if case .available(let offer) = state { offer } else { nil }
    }

    /// At launch: checks quietly at most once a day; shows the window only when there is an update.
    func checkAutomaticallyIfDue() {
        guard checksAutomatically, canUpdate else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.checkInterval else { return }
        check(userInitiated: false)
    }

    /// "Check for Updates…": always shows the result.
    func check(userInitiated: Bool) {
        if case .downloading = state { showingWindow = true; return }
        if case .installing = state { showingWindow = true; return }
        guard canUpdate else {
            state = .failed(String(localized: "Updates work only in the installed app."), offer: nil)
            showingWindow = userInitiated
            return
        }
        task?.cancel()
        state = .checking
        if userInitiated { showingWindow = true }
        task = Task {
            do {
                let offer = try await fetchOffer()
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                if let offer {
                    state = .available(offer)
                    showingWindow = true
                    // Developer test: with a local feed, install right away (same path as the button).
                    let env = ProcessInfo.processInfo.environment
                    if env["PPB_UPDATE_FEED"] != nil, env["PPB_UPDATE_AUTOINSTALL"] == "1" {
                        install(offer, isBusy: false)
                    }
                } else {
                    state = .upToDate
                }
            } catch is CancellationError {
            } catch {
                state = .failed(String(localized: "Could not check for updates: \(error.localizedDescription)"), offer: nil)
                if !userInitiated { showingWindow = false }
            }
        }
    }

    private func fetchOffer() async throws -> AppUpdateOffer? {
        var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("PhonePhotoBackup/\(Self.currentVersionText)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { return nil } // no release published yet
            guard (200..<300).contains(http.statusCode) else {
                throw AppUpdate.Failure.tool("HTTP \(http.statusCode)")
            }
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let current = AppVersion(Self.currentVersionText) else { return nil }
        return AppUpdate.offer(current: current, release: release)
    }

    /// Downloads, verifies and installs `offer`, then quits so the new version starts.
    func install(_ offer: AppUpdateOffer, isBusy: Bool) {
        guard !isBusy else { return }
        guard let sha256 = offer.sha256 else {
            NSWorkspace.shared.open(offer.pageURL)
            return
        }
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            state = .failed(String(localized: "This app's folder (\(parent.path)) cannot be changed. Download the new version from the release page instead."), offer: offer)
            return
        }
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        state = .downloading(offer, fraction: 0)
        task = Task {
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("PhonePhotoBackup-update-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let zip = try await download(offer.downloadURL, to: work.appendingPathComponent("update.zip")) { fraction in
                    if case .downloading = self.state { self.state = .downloading(offer, fraction: fraction) }
                }
                state = .installing(offer)
                let app = try await Task.detached(priority: .userInitiated) {
                    try AppUpdate.unpack(zip: zip, sha256: sha256, into: work.appendingPathComponent("unpacked"),
                                         bundleIdentifier: bundleID, version: offer.version)
                }.value
                let script = AppUpdate.installScript(pid: ProcessInfo.processInfo.processIdentifier, newApp: app,
                                                     target: target, workDirectory: work,
                                                     relaunch: ["/usr/bin/open", target.path])
                let scriptURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("PhonePhotoBackup-install-\(UUID().uuidString).sh")
                try script.write(to: scriptURL, atomically: true, encoding: .utf8)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = [scriptURL.path]
                try process.run()
                // An open sheet makes macOS refuse to quit, so close them first. If quitting is
                // still refused, exit: nothing is running (installing needs the app to be idle).
                showingWindow = false
                for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
                try? await Task.sleep(for: .milliseconds(500))
                NSApp.terminate(nil)
                try? await Task.sleep(for: .seconds(5))
                exit(0)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: work)
                state = .available(offer)
            } catch {
                try? FileManager.default.removeItem(at: work)
                state = .failed(error.localizedDescription, offer: offer)
            }
        }
    }

    func cancelDownload() {
        task?.cancel()
    }

    func later() {
        if case .downloading = state { return }
        if case .installing = state { return }
        showingWindow = false
    }

    private func download(_ url: URL, to destination: URL,
                          progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let box = DownloadBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                var request = URLRequest(url: url, timeoutInterval: 60)
                request.setValue("PhonePhotoBackup/\(Self.currentVersionText)", forHTTPHeaderField: "User-Agent")
                let task = URLSession.shared.downloadTask(with: request) { location, response, error in
                    if let error {
                        continuation.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
                        return
                    }
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        continuation.resume(throwing: AppUpdate.Failure.tool("HTTP \(http.statusCode)"))
                        return
                    }
                    guard let location else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                        return
                    }
                    do {
                        try FileManager.default.moveItem(at: location, to: destination)
                        continuation.resume(returning: destination)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.task = task
                box.observation = task.progress.observe(\.fractionCompleted) { value, _ in
                    let fraction = value.fractionCompleted
                    Task { @MainActor in progress(fraction) }
                }
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }
}

private final class DownloadBox: @unchecked Sendable {
    var task: URLSessionDownloadTask?
    var observation: NSKeyValueObservation?
}

/// The update window: what is new, and Install and Restart.
struct UpdateSheet: View {
    @Environment(BackupModel.self) private var model
    @Bindable var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.down.app.fill").font(.system(size: 34)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.weight(.semibold))
                    Text("Current version: \(Updater.currentVersionText) (\(Updater.currentBuildText))")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            content
            Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
                .toggleStyle(.checkbox)
                .font(.callout)
            buttons
        }
        .padding(20)
        .frame(width: 520)
    }

    private var title: LocalizedStringKey {
        switch updater.state {
        case .idle, .checking: "Checking for updates…"
        case .upToDate: "Phone Photo Backup is up to date"
        case .available(let offer): "Version \(offer.version.description) is available"
        case .downloading(let offer, _): "Downloading version \(offer.version.description)…"
        case .installing(let offer): "Installing version \(offer.version.description)…"
        case .failed: "Update problem"
        }
    }

    @ViewBuilder private var content: some View {
        switch updater.state {
        case .idle, .checking:
            ProgressView().controlSize(.small)
        case .upToDate:
            Text("You have the latest version.").foregroundStyle(.secondary)
        case .available(let offer):
            notes(offer)
            if model.isBusy {
                Label("Finish or stop the current backup or import first.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if offer.sha256 == nil {
                Text("This release has no checksum, so it cannot be installed automatically. Open the release page to download it.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("The app downloads the new version, checks it and restarts. Your settings and backups are kept.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .downloading(let offer, let fraction):
            ProgressView(value: fraction) {
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(Double(offer.size) * fraction), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: offer.size, countStyle: .file))")
                    .font(.callout.monospacedDigit())
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking the download and restarting…").foregroundStyle(.secondary)
            }
        case .failed(let message, _):
            Text(verbatim: message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func notes(_ offer: AppUpdateOffer) -> some View {
        ScrollView {
            Text(offer.notes.isEmpty ? String(localized: "No release notes.") : offer.notes)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(height: 140)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            switch updater.state {
            case .available(let offer):
                Button("Release Page") { NSWorkspace.shared.open(offer.pageURL) }
                Spacer()
                Button("Later") { updater.later() }.keyboardShortcut(.cancelAction)
                Button(offer.sha256 == nil ? "Open Release Page" : "Install and Restart") {
                    updater.install(offer, isBusy: model.isBusy)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy)
            case .downloading:
                Spacer()
                Button("Cancel") { updater.cancelDownload() }.keyboardShortcut(.cancelAction)
            case .installing:
                Spacer()
            case .failed(_, let offer):
                if let offer {
                    Button("Release Page") { NSWorkspace.shared.open(offer.pageURL) }
                }
                Spacer()
                Button("OK") { updater.later() }.keyboardShortcut(.defaultAction)
            default:
                Spacer()
                Button("OK") { updater.later() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
