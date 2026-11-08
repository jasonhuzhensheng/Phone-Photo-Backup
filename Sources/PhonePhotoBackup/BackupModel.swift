import AppKit
import BackupCore
import Foundation
import Observation

@MainActor @Observable
final class BackupModel {
    enum Phase: Equatable {
        case idle, scanning, ready, backingUp, importing, finished
    }

    enum ImportStage: Equatable {
        case preparing, checkingLibrary, importing
    }

    struct ImportReport {
        var imported = 0
        var alreadyInPhotos = 0
        var duplicates = 0
        var previouslyImported = 0
        var errors: [String] = []
        var cancelled = false
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

    // Importing into Photos
    private(set) var importStage = ImportStage.preparing
    private(set) var importDone = 0
    private(set) var importTotal = 0
    private(set) var importReport: ImportReport?
    /// Item count and size shown while asking whether to import.
    private(set) var pendingImport: (count: Int, bytes: Int64)?
    var confirmingImport = false
    @ObservationIgnored private var importDecision: CheckedContinuation<Bool, Never>?

    /// Import new photos and videos into Photos after each backup.
    var importToPhotos: Bool {
        didSet { UserDefaults.standard.set(importToPhotos, forKey: Self.importKey) }
    }
    /// Scan, back up (and import) as soon as a phone is connected, with no questions.
    var autoStart: Bool {
        didSet {
            UserDefaults.standard.set(autoStart, forKey: Self.autoStartKey)
            if autoStart, case .device(let id) = source { runAutomaticallyIfNeeded(id) }
        }
    }
    /// Phones already handled automatically since the app started.
    @ObservationIgnored private var autoRan: Set<String> = []
    /// The developer self-check must never touch a real phone or the Photos library.
    private let isSelfCheck = ProcessInfo.processInfo.environment["PPB_SNAPSHOT_DIR"] != nil

    private var task: Task<Void, Never>?
    private static let sourceKey = "sourcePath", destinationKey = "destinationPath"
    private static let importKey = "importToPhotos", autoStartKey = "autoStartOnConnect"

    init() {
        let defaults = UserDefaults.standard
        source = Self.existingFolder(defaults.string(forKey: Self.sourceKey)).map(Source.folder)
        destinationURL = Self.existingFolder(defaults.string(forKey: Self.destinationKey))
        importToPhotos = defaults.bool(forKey: Self.importKey)
        autoStart = defaults.bool(forKey: Self.autoStartKey)
        devices.onDeviceAdded = { [weak self] id in self?.deviceConnected(id) }
        devices.onDeviceRemoved = { [weak self] id in self?.deviceDisconnected(id) }
        if !isSelfCheck {
            devices.start()
        }
    }

    var sourceURL: URL? {
        if case .folder(let url) = source { url } else { nil }
    }

    var sourceDevice: DeviceBrowser.Device? {
        if case .device(let id) = source { devices.device(id) } else { nil }
    }

    var isBusy: Bool { phase == .scanning || phase == .backingUp || phase == .importing }
    var canScan: Bool { !isBusy && source != nil && destinationURL != nil }
    var canImport: Bool { !isBusy && destinationURL != nil }
    private var importsAfterBackup: Bool { importToPhotos && !isSelfCheck }
    var canStart: Bool { !isBusy && plan != nil && phase == .ready }

    var fractionComplete: Double {
        if phase == .importing {
            return importTotal > 0 ? Double(importDone) / Double(importTotal) : 0
        }
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

    /// A phone that is plugged in while the app is idle becomes the source. In automatic mode it
    /// is then scanned, backed up and (if chosen) imported into Photos right away.
    private func deviceConnected(_ id: String) {
        guard !isBusy else { return }
        if sourceDevice == nil || autoStart { setSourceDevice(id) }
        runAutomaticallyIfNeeded(id)
    }

    private func runAutomaticallyIfNeeded(_ id: String) {
        guard autoStart, !isSelfCheck, !isBusy, source == .device(id), destinationURL != nil,
              !autoRan.contains(id) else { return }
        autoRan.insert(id)
        scan()
        let scanning = task
        Task {
            await scanning?.value
            guard phase == .ready, source == .device(id) else { return }
            startBackup()
        }
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

    private func invalidatePlan() {
        plan = nil
        report = nil
        importReport = nil
        phase = .idle
    }

    // MARK: Actions

    func scan() {
        guard canScan, let source, let destination = destinationURL else { return }
        plan = nil
        report = nil
        importReport = nil
        phase = .scanning
        task = Task {
            let result: Result<BackupPlan, Error>
            switch source {
            case .folder(let folder):
                result = await Task.detached(priority: .userInitiated) {
                    Result { try BackupEngine.makePlan(source: folder, destination: destination) }
                }.value
            case .device(let id):
                do {
                    try await devices.waitUntilReady(id)
                    let catalog = try devices.catalog(of: id)
                    result = .success(BackupEngine.makeDevicePlan(deviceName: catalog.name, deviceID: id,
                                                                  files: catalog.files, destination: destination))
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
        importReport = nil

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
                            try await devices.download(deviceID: deviceID, path: file.relativePath, into: directory)
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
                if self.importsAfterBackup, !report.cancelled, let destination = self.destinationURL {
                    await self.performImport(folders: [report.backupDirectory], destination: destination, confirm: false)
                } else {
                    self.phase = .finished
                    self.announceFinished()
                }
            case .failure(let error):
                self.phase = .ready
                self.alertMessage = error.localizedDescription
            }
        }
    }

    // MARK: Importing into Photos

    /// Imports every backup in the backup location into Photos, after showing what will be added.
    func importAllBackups() {
        guard canImport, let destination = destinationURL else { return }
        let folders = PhotosImport.backupFolders(in: destination)
        guard !folders.isEmpty else {
            alertMessage = String(localized: "There are no backups in the backup location yet.")
            return
        }
        report = nil
        task = Task { await performImport(folders: folders, destination: destination, confirm: true) }
    }

    func answerImport(_ yes: Bool) {
        confirmingImport = false
        importDecision?.resume(returning: yes)
        importDecision = nil
    }

    private func askToImport(count: Int, bytes: Int64) async -> Bool {
        pendingImport = (count, bytes)
        return await withCheckedContinuation { continuation in
            importDecision = continuation
            confirmingImport = true
        }
    }

    /// Adds the photos and videos in `folders` that are not in Photos yet. Identical files in
    /// several backups are added once; files already imported (recorded in the ledger) or already
    /// in the library (same name and capture time) are skipped.
    private func performImport(folders: [URL], destination: URL, confirm: Bool) async {
        guard !isSelfCheck else { phase = .finished; return }
        phase = .importing
        importStage = .preparing
        importDone = 0
        importTotal = 0
        currentFile = ""
        importReport = nil
        var result = ImportReport()
        do {
            try await PhotoLibraryImporter.authorize()
            var ledger = try ImportLedger.load(from: destination)
            let snapshot = ledger
            let plan = try await Task.detached(priority: .userInitiated) {
                try PhotosImport.makePlan(backupFolders: folders, ledger: snapshot)
            }.value
            result.duplicates = plan.duplicateFiles
            result.previouslyImported = plan.previouslyImportedFiles

            if !plan.items.isEmpty {
                if confirm, !(await askToImport(count: plan.items.count, bytes: plan.totalBytes)) {
                    phase = report == nil ? .idle : .finished
                    return
                }
                importStage = .checkingLibrary
                let index = await Task.detached(priority: .userInitiated) { PhotoLibraryImporter.libraryIndex() }.value
                importStage = .importing
                importTotal = plan.items.count

                for item in plan.items {
                    if Task.isCancelled {
                        result.cancelled = true
                        break
                    }
                    currentFile = item.primary.filename
                    let date = await PhotoLibraryImporter.captureDate(of: item.primary.url)
                    if index.contains(filename: item.primary.filename, date: date) {
                        ledger.record(item, assetID: nil, existing: true)
                        result.alreadyInPhotos += 1
                    } else {
                        do {
                            let id = try await PhotoLibraryImporter.add(item)
                            ledger.record(item, assetID: id, existing: false)
                            result.imported += 1
                        } catch {
                            result.errors.append("\(item.primary.url.path): \(error.localizedDescription)")
                        }
                    }
                    importDone += 1
                    if importDone % 25 == 0 { try? ledger.write(to: destination) }
                }
            }
            do {
                try ledger.write(to: destination)
            } catch {
                result.errors.append(String(localized: "The import record could not be saved: \(error.localizedDescription)"))
            }
            importReport = result
            phase = .finished
            announceFinished()
        } catch {
            importReport = result
            phase = report == nil ? .idle : .finished
            alertMessage = error.localizedDescription
        }
    }

    private func announceFinished() {
        NSApp.requestUserAttention(.informationalRequest)
        if autoStart { NSSound(named: "Glass")?.play() }
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
