import AppKit
import BackupCore
import Foundation
import Observation

@MainActor @Observable
final class BackupModel {
    enum Phase: Equatable {
        case idle, scanning, ready, backingUp, finished
    }

    /// Where files are read from: a folder on this Mac, or a phone connected over USB.
    enum Source: Equatable {
        case folder(URL)
        case device(String)
    }

    let devices = DeviceBrowser()
    private(set) var source: Source?
    private(set) var destinationURL: URL?
    private(set) var plan: BackupPlan?
    private(set) var phase: Phase = .idle
    private(set) var processedFiles = 0
    private(set) var processedBytes: Int64 = 0
    private(set) var currentFile = ""
    private(set) var report: BackupReport?
    var alertMessage: String?
    var confirmingStart = false
    /// Folders already backed up elsewhere (another drive, an old export…) to compare with.
    private(set) var referenceFolders: [URL] = []
    /// Free space on the backup volume, measured when scanning.
    private(set) var freeSpace: Int64?

    private var task: Task<Void, Never>?
    private static let sourceKey = "sourcePath", destinationKey = "destinationPath", referencesKey = "referencePaths"

    init() {
        let defaults = UserDefaults.standard
        source = Self.existingFolder(defaults.string(forKey: Self.sourceKey)).map(Source.folder)
        destinationURL = Self.existingFolder(defaults.string(forKey: Self.destinationKey))
        referenceFolders = (defaults.stringArray(forKey: Self.referencesKey) ?? []).compactMap(Self.existingFolder)
        devices.onDeviceAdded = { [weak self] id in self?.deviceConnected(id) }
        devices.onDeviceRemoved = { [weak self] id in self?.deviceDisconnected(id) }
        // The developer self-check must only ever touch its temporary folders, never a real phone.
        if ProcessInfo.processInfo.environment["PPB_SNAPSHOT_DIR"] == nil {
            devices.start()
        }
    }

    var sourceURL: URL? {
        if case .folder(let url) = source { url } else { nil }
    }

    var sourceDevice: DeviceBrowser.Device? {
        if case .device(let id) = source { devices.device(id) } else { nil }
    }

    var isBusy: Bool { phase == .scanning || phase == .backingUp }
    var canScan: Bool { !isBusy && source != nil && destinationURL != nil }
    var canStart: Bool { !isBusy && plan != nil && phase == .ready }

    var fractionComplete: Double {
        guard let plan else { return 0 }
        if plan.totalBytes > 0 { return min(1, Double(processedBytes) / Double(plan.totalBytes)) }
        return plan.files.isEmpty ? 1 : Double(processedFiles) / Double(plan.files.count)
    }

    // MARK: Folder selection

    func setSource(_ url: URL) {
        guard !isBusy else { return }
        source = .folder(url)
        UserDefaults.standard.set(url.path, forKey: Self.sourceKey)
        invalidatePlan()
    }

    func setSourceDevice(_ id: String) {
        guard !isBusy, source != .device(id) else { return }
        source = .device(id)
        invalidatePlan()
    }

    /// A phone that is plugged in while the app is idle becomes the source.
    private func deviceConnected(_ id: String) {
        if !isBusy, sourceDevice == nil { setSourceDevice(id) }
    }

    private func deviceDisconnected(_ id: String) {
        guard source == .device(id) else { return }
        // A running backup waits for the phone to come back (see DeviceBrowser.download).
        if phase == .backingUp { return }
        if phase == .scanning {
            cancel()
            alertMessage = DeviceBrowser.DeviceError.disconnected.localizedDescription
            return
        }
        source = Self.existingFolder(UserDefaults.standard.string(forKey: Self.sourceKey)).map(Source.folder)
        if let other = devices.devices.first { source = .device(other.id) }
        invalidatePlan()
    }

    func setDestination(_ url: URL) {
        guard !isBusy else { return }
        destinationURL = url
        UserDefaults.standard.set(url.path, forKey: Self.destinationKey)
        invalidatePlan()
    }

    func chooseSource() {
        let start = sourceURL ?? Self.existingFolder(UserDefaults.standard.string(forKey: Self.sourceKey))
        if let url = Self.pickFolder(message: String(localized: "Choose the folder exported from your phone."),
                                     startingAt: start, allowCreate: false) {
            setSource(url)
        }
    }

    func chooseDestination() {
        if let url = Self.pickFolder(message: String(localized: "Choose where the backup folder should be created."),
                                     startingAt: destinationURL, allowCreate: true) {
            setDestination(url)
        }
    }

    // MARK: Reference folders

    func addReferenceFolders() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose folders that are already backed up. Files found in them are not backed up again.")
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !referenceFolders.contains(url) { referenceFolders.append(url) }
        saveReferences()
    }

    func removeReferenceFolder(_ url: URL) {
        guard !isBusy else { return }
        referenceFolders.removeAll { $0 == url }
        saveReferences()
    }

    private func saveReferences() {
        UserDefaults.standard.set(referenceFolders.map(\.path), forKey: Self.referencesKey)
        invalidatePlan()
    }

    private func invalidatePlan() {
        plan = nil
        report = nil
        phase = .idle
    }

    // MARK: Actions

    func scan() {
        guard canScan, let source, let destination = destinationURL else { return }
        let references = referenceFolders.filter { FileManager.default.fileExists(atPath: $0.path) }
        freeSpace = (try? destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        plan = nil
        report = nil
        phase = .scanning
        task = Task {
            let result: Result<BackupPlan, Error>
            switch source {
            case .folder(let folder):
                result = await Task.detached(priority: .userInitiated) {
                    Result { try BackupEngine.makePlan(source: folder, destination: destination, references: references) }
                }.value
            case .device(let id):
                do {
                    try await devices.waitUntilReady(id)
                    let catalog = try devices.catalog(of: id)
                    // Indexing reference folders can take a moment: do it off the main thread.
                    result = .success(await Task.detached(priority: .userInitiated) {
                        BackupEngine.makeDevicePlan(deviceName: catalog.name, files: catalog.files,
                                                    destination: destination, references: references)
                    }.value)
                } catch {
                    result = .failure(error)
                }
            }
            guard !Task.isCancelled, phase == .scanning else {
                if phase == .scanning { phase = .idle }
                return
            }
            switch result {
            case .success(let plan):
                self.plan = plan
                self.phase = .ready
            case .failure(let error):
                self.phase = .idle
                if !(error is CancellationError) { self.alertMessage = error.localizedDescription }
            }
        }
    }

    func requestStart() {
        if canStart { confirmingStart = true }
    }

    func startBackup() {
        guard canStart, let plan else { return }
        phase = .backingUp
        processedFiles = 0
        processedBytes = 0
        currentFile = ""
        report = nil

        task = Task {
            // Keep the Mac awake while copying.
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Backing up phone photos")
            defer { ProcessInfo.processInfo.endActivity(activity) }

            let progress: BackupProgress = { index, _, file, _ in
                Task { @MainActor in self.recordProgress(index: index, file: file) }
            }
            let deviceID: String? = if case .device(let id) = source { id } else { nil }
            let devices = self.devices
            let worker = Task.detached(priority: .userInitiated) { () -> Result<BackupReport, Error> in
                do {
                    if let deviceID {
                        return .success(try await BackupEngine.runStaged(plan, fetch: { file, directory in
                            try await devices.download(deviceID: deviceID, path: file.relativePath, size: file.size, into: directory)
                        }, isCancelled: { Task.isCancelled }, progress: progress))
                    }
                    return .success(try BackupEngine.run(plan, isCancelled: { Task.isCancelled }, progress: progress))
                } catch {
                    return .failure(error)
                }
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            await Task.yield() // let queued progress updates land first
            switch result {
            case .success(let report):
                self.report = report
                self.phase = .finished
                NSApp.requestUserAttention(.informationalRequest)
            case .failure(let error):
                self.phase = .ready
                self.alertMessage = error.localizedDescription
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func recordProgress(index: Int, file: PlannedFile) {
        guard phase == .backingUp, index > processedFiles else { return }
        processedFiles = index
        processedBytes += file.size
        currentFile = file.relativePath
    }

    func revealBackupFolder() {
        guard let url = report?.backupDirectory ?? plan?.backupDirectory else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if let destinationURL {
            NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
        }
    }

    // MARK: Helpers

    private static func existingFolder(_ path: String?) -> URL? {
        guard let path else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func pickFolder(message: String, startingAt url: URL?, allowCreate: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = allowCreate
        panel.message = message
        panel.prompt = String(localized: "Choose")
        panel.directoryURL = url
        return panel.runModal() == .OK ? panel.url : nil
    }
}
