import AppKit
import BackupCore
import Foundation
import Observation

@MainActor @Observable
final class BackupModel {
    enum Phase: Equatable {
        case idle, scanning, ready, backingUp, deleting, importing, finished
    }

    struct DeletionReport {
        var requested = 0
        var deleted = 0
        /// Selected, but without a verified backup copy, so not deleted.
        var notBackedUp: [String] = []
        /// Selected, but not matched to exactly one item in Photos, so not deleted.
        var notInPhotos: [String] = []
        var error: String?
        /// Phone paths of the items that were moved to Recently Deleted.
        var deletedPaths: [String] = []
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

    // Review before backup and deleting through Photos
    private(set) var review: ReviewSession?
    private(set) var deletionReport: DeletionReport?
    @ObservationIgnored private var pendingDeletion: (items: [PhoneItem], requireBackup: Bool)?
    /// "Delete first" in progress from the review list; Cancel stops it before anything is deleted.
    @ObservationIgnored private var deletionTask: Task<Void, Never>?
    /// Show the largest videos and duplicates before backing up a phone.
    var reviewBeforeBackup: Bool {
        didSet { UserDefaults.standard.set(reviewBeforeBackup, forKey: Self.reviewKey) }
    }

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
    private static let reviewKey = "reviewBeforeBackup"

    init() {
        let defaults = UserDefaults.standard
        source = Self.existingFolder(defaults.string(forKey: Self.sourceKey)).map(Source.folder)
        destinationURL = Self.existingFolder(defaults.string(forKey: Self.destinationKey))
        importToPhotos = defaults.bool(forKey: Self.importKey)
        autoStart = defaults.bool(forKey: Self.autoStartKey)
        reviewBeforeBackup = defaults.object(forKey: Self.reviewKey) as? Bool ?? true
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

    var isBusy: Bool { phase == .scanning || phase == .backingUp || phase == .deleting || phase == .importing }
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
        deletionReport = nil
        phase = .idle
    }

    // MARK: Actions

    func scan() {
        guard canScan, let source, let destination = destinationURL else { return }
        plan = nil
        report = nil
        importReport = nil
        deletionReport = nil
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

    /// For a phone, opens the review of large videos and duplicates first (when turned on);
    /// otherwise asks to confirm the backup.
    func requestStart() {
        guard canStart else { return }
        if reviewBeforeBackup, !isSelfCheck, case .device(let id) = source {
            let session = ReviewSession(deviceID: id)
            review = session
            session.start(devices: devices)
        } else {
            confirmingStart = true
        }
    }

    func closeReview() {
        deletionTask?.cancel()
        deletionTask = nil
        review?.cancel()
        review = nil
    }

    /// Ends the review and starts the backup. With `delete`, the selected items are deleted
    /// through Photos once the backup has finished (or are left out of the backup, if chosen).
    func finishReview(delete: Bool) {
        guard let review, let plan else { return }
        review.cancel()
        self.review = nil
        pendingDeletion = nil
        if delete, !review.selected.isEmpty {
            pendingDeletion = (review.selectedItems, review.backUpSelected)
            if !review.backUpSelected {
                self.plan = plan.excluding(review.selected)
            }
        }
        startBackup()
    }

    func startBackup() {
        guard canStart, let plan else { return }
        phase = .backingUp
        processedFiles = 0
        processedBytes = 0
        currentFile = ""
        report = nil
        importReport = nil
        deletionReport = nil

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
                if let pending = self.pendingDeletion, !report.cancelled, let destination = self.destinationURL {
                    self.pendingDeletion = nil
                    await self.performDeletion(pending.items, requireBackup: pending.requireBackup,
                                               backupDirectory: report.backupDirectory, destination: destination)
                }
                self.pendingDeletion = nil
                if self.importsAfterBackup, !report.cancelled, let destination = self.destinationURL {
                    await self.performImport(folders: [report.backupDirectory], destination: destination, confirm: false)
                } else {
                    self.phase = .finished
                    self.announceFinished()
                }
            case .failure(let error):
                self.pendingDeletion = nil
                self.phase = .ready
                self.alertMessage = error.localizedDescription
            }
        }
    }

    // MARK: Deleting through Photos

    /// Moves the selected items to Recently Deleted in Photos (recoverable for 30 days); iCloud
    /// Photos then removes them from the phone. With `requireBackup`, only items whose backup copy
    /// is verified are deleted. Items are matched to Photos by name and capture time; anything
    /// without exactly one match is left alone.
    private func performDeletion(_ items: [PhoneItem], requireBackup: Bool, backupDirectory: URL, destination: URL) async {
        phase = .deleting
        deletionReport = await deleteThroughPhotos(items, requireBackup: requireBackup,
                                                   backupDirectory: backupDirectory, destination: destination)
    }

    /// "Delete first, then back up": moves the selected items to Recently Deleted in Photos, takes
    /// the deleted ones out of the backup and then backs up the rest of the phone. Items not found
    /// in Photos stay on the phone and are backed up. If deleting fails (no permission, the macOS
    /// prompt was declined) the list stays open with the error and nothing is backed up.
    func deleteSelectedThenBackUp() {
        guard let review, !review.isDeleting, !review.selected.isEmpty else { return }
        let items = review.selectedItems
        let backupDirectory = plan?.backupDirectory
        let destination = destinationURL
        review.beginDeletion()
        deletionTask = Task {
            let result = await deleteThroughPhotos(items, requireBackup: false,
                                                   backupDirectory: backupDirectory, destination: destination)
            let removed = Set(result.deletedPaths)
            if let plan = self.plan, !removed.isEmpty { self.plan = plan.excluding(removed) }
            review.finishDeletion(result, removed: removed)
            guard result.error == nil, self.review === review else { return }
            review.cancel()
            self.review = nil
            self.pendingDeletion = nil
            self.startBackup()
            self.deletionReport = result // shown with the backup result
        }
    }

    /// Finds `items` in Photos (one strict match each) and moves them to Recently Deleted.
    /// With `requireBackup`, only items with a verified copy in `backupDirectory` are deleted.
    private func deleteThroughPhotos(_ items: [PhoneItem], requireBackup: Bool,
                                     backupDirectory: URL?, destination: URL?) async -> DeletionReport {
        var result = DeletionReport(requested: items.count)
        do {
            try await PhotoLibraryImporter.authorize()
            var candidates = items
            if requireBackup {
                let split = backupDirectory.map { PhoneReview.backedUp(items, in: $0) } ?? (safe: [], missing: items)
                candidates = split.safe
                result.notBackedUp = split.missing.map(\.relativePath)
            }
            let lookup = candidates.map { (path: $0.relativePath, filename: $0.filename, date: $0.date) }
            let finder = Task.detached(priority: .userInitiated) { try PhotoLibraryImporter.uniqueMatches(for: lookup) }
            let found = try await withTaskCancellationHandler { try await finder.value } onCancel: { finder.cancel() }
            try Task.checkCancellation() // the user can still stop here; nothing has been deleted yet
            var identifiers: [String] = []
            var matched: [PhoneItem] = []
            for item in candidates {
                if let id = found[item.relativePath] {
                    identifiers.append(id)
                    matched.append(item)
                } else {
                    result.notInPhotos.append(item.relativePath)
                }
            }
            if !identifiers.isEmpty {
                result.deleted = try await PhotoLibraryImporter.moveToRecentlyDeleted(identifiers)
                result.deletedPaths = matched.map(\.relativePath)
                // Keep a later import from putting backed-up copies back into Photos.
                if let destination, let backupDirectory {
                    var ledger = try ImportLedger.load(from: destination)
                    for sha in PhoneReview.backupHashes(of: matched, in: backupDirectory).values {
                        ledger.markDeleted(sha)
                    }
                    try ledger.write(to: destination)
                }
            }
        } catch {
            result.error = error.localizedDescription
        }
        return result
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

    /// True when the source is a phone and nothing else is running.
    var canImportPhone: Bool {
        guard !isBusy, !isSelfCheck, case .device = source else { return false }
        return true
    }

    /// Imports the phone's photos and videos straight into Photos, without saving a backup.
    func importPhoneDirectly() {
        guard canImportPhone, case .device(let id) = source else { return }
        report = nil
        deletionReport = nil
        task = Task { await performDirectImport(deviceID: id) }
    }

    /// Where the import record is kept: the backup location when one is chosen (shared with
    /// imports from backups), otherwise the app's own folder in Application Support.
    private func importRecordFolder() throws -> URL {
        if let destinationURL { return destinationURL }
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
            .appendingPathComponent("Phone Photo Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Phone → Photos without a backup. For each photo, video or Live Photo, oldest first:
    /// 1. skipped without reading it when an earlier direct import handled it (import record);
    /// 2. skipped without reading it when Photos already has the same name and capture time
    ///    (time from the phone's file list);
    /// 3. otherwise read from the phone into a temporary folder, checked again with the capture
    ///    time from the file itself and against the import record by SHA-256 (the same bytes
    ///    from a backup import or in another folder), then added to Photos;
    /// 4. the temporary copy is removed. Nothing is written to the backup location except the
    ///    import record.
    private func performDirectImport(deviceID id: String) async {
        phase = .importing
        importStage = .preparing
        importDone = 0
        importTotal = 0
        currentFile = ""
        importReport = nil
        var result = ImportReport()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhonePhotoBackup-import-\(getpid())-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try await PhotoLibraryImporter.authorize()
            let recordFolder = try importRecordFolder()
            var ledger = try ImportLedger.load(from: recordFolder)
            try await devices.waitUntilReady(id)
            _ = try devices.catalog(of: id)
            let all = PhotosImport.phoneItems(devices.items(of: id))
            let todo = all.filter { !ledger.handled($0, deviceID: id) }
            result.previouslyImported = all.count - todo.count

            if !todo.isEmpty {
                guard await askToImport(count: todo.count, bytes: todo.reduce(0) { $0 + $1.size }) else {
                    phase = .idle
                    return
                }
                importStage = .checkingLibrary
                let library = await Task.detached(priority: .userInitiated) { PhotoLibraryImporter.libraryLookup() }.value
                importStage = .importing
                importTotal = todo.count
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                var seen: Set<String> = []

                for item in todo {
                    if Task.isCancelled {
                        result.cancelled = true
                        break
                    }
                    currentFile = item.primary.filename
                    defer {
                        importDone += 1
                        if importDone % 25 == 0 { try? ledger.write(to: recordFolder) }
                    }
                    if library.contains(filename: item.primary.filename, date: item.primary.date) {
                        ledger.recordPhone(item, deviceID: id, sha256: [:])
                        result.alreadyInPhotos += 1
                        continue
                    }
                    var downloaded: [URL] = []
                    defer { downloaded.forEach { try? FileManager.default.removeItem(at: $0) } }
                    do {
                        var files: [String: ImportFile] = [:]
                        var hashes: [String: String] = [:]
                        for file in item.files {
                            let url = try await devices.download(deviceID: id, path: file.relativePath, into: staging)
                            downloaded.append(url)
                            let sha = try await Task.detached { try BackupEngine.sha256(of: url.path) }.value
                            files[file.relativePath] = ImportFile(url: url, sha256: sha, size: file.size)
                            hashes[file.relativePath] = sha
                        }
                        let importItem = ImportItem(photo: item.photo.flatMap { files[$0.relativePath] },
                                                    video: item.video.flatMap { files[$0.relativePath] })
                        let shas = importItem.files.map(\.sha256)
                        if shas.allSatisfy({ seen.contains($0) }) {
                            result.duplicates += 1
                        } else if shas.allSatisfy(ledger.contains) {
                            result.previouslyImported += 1
                        } else if library.contains(filename: importItem.primary.filename,
                                                   date: await PhotoLibraryImporter.captureDate(of: importItem.primary.url)) {
                            ledger.record(importItem, assetID: nil, existing: true)
                            result.alreadyInPhotos += 1
                        } else {
                            let assetID = try await PhotoLibraryImporter.add(importItem)
                            ledger.record(importItem, assetID: assetID, existing: false)
                            library.add(filename: importItem.primary.filename, date: item.primary.date, id: assetID)
                            result.imported += 1
                        }
                        seen.formUnion(shas)
                        ledger.recordPhone(item, deviceID: id, sha256: hashes)
                    } catch is CancellationError {
                        result.cancelled = true
                        break
                    } catch {
                        result.errors.append("\(item.primary.relativePath): \(error.localizedDescription)")
                    }
                }
            }
            do {
                try ledger.write(to: recordFolder)
            } catch {
                result.errors.append(String(localized: "The import record could not be saved: \(error.localizedDescription)"))
            }
            importReport = result
            phase = .finished
            announceFinished()
        } catch {
            importReport = result
            phase = .idle
            if !(error is CancellationError) { alertMessage = error.localizedDescription }
        }
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
                let index = await Task.detached(priority: .userInitiated) { PhotoLibraryImporter.libraryLookup() }.value
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
