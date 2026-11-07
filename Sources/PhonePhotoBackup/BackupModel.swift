import AppKit
import BackupCore
import Foundation
import Observation

@MainActor @Observable
final class BackupModel {
    enum Phase: Equatable {
        case idle, scanning, ready, backingUp, finished
    }

    private(set) var sourceURL: URL?
    private(set) var destinationURL: URL?
    private(set) var plan: BackupPlan?
    private(set) var phase: Phase = .idle
    private(set) var processedFiles = 0
    private(set) var processedBytes: Int64 = 0
    private(set) var currentFile = ""
    private(set) var report: BackupReport?
    var alertMessage: String?
    var confirmingStart = false

    private var task: Task<Void, Never>?
    private static let sourceKey = "sourcePath", destinationKey = "destinationPath"

    init() {
        let defaults = UserDefaults.standard
        sourceURL = Self.existingFolder(defaults.string(forKey: Self.sourceKey))
        destinationURL = Self.existingFolder(defaults.string(forKey: Self.destinationKey))
    }

    var isBusy: Bool { phase == .scanning || phase == .backingUp }
    var canScan: Bool { !isBusy && sourceURL != nil && destinationURL != nil }
    var canStart: Bool { !isBusy && plan != nil && phase == .ready }

    var fractionComplete: Double {
        guard let plan else { return 0 }
        if plan.totalBytes > 0 { return min(1, Double(processedBytes) / Double(plan.totalBytes)) }
        return plan.files.isEmpty ? 1 : Double(processedFiles) / Double(plan.files.count)
    }

    // MARK: Folder selection

    func setSource(_ url: URL) {
        guard !isBusy else { return }
        sourceURL = url
        UserDefaults.standard.set(url.path, forKey: Self.sourceKey)
        invalidatePlan()
    }

    func setDestination(_ url: URL) {
        guard !isBusy else { return }
        destinationURL = url
        UserDefaults.standard.set(url.path, forKey: Self.destinationKey)
        invalidatePlan()
    }

    func chooseSource() {
        if let url = Self.pickFolder(message: String(localized: "Choose the folder exported from your phone."),
                                     startingAt: sourceURL, allowCreate: false) {
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
        phase = .idle
    }

    // MARK: Actions

    func scan() {
        guard canScan, let source = sourceURL, let destination = destinationURL else { return }
        plan = nil
        report = nil
        phase = .scanning
        task = Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try BackupEngine.makePlan(source: source, destination: destination) }
            }.value
            switch result {
            case .success(let plan):
                self.plan = plan
                self.phase = .ready
            case .failure(let error):
                self.phase = .idle
                self.alertMessage = error.localizedDescription
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

            let worker = Task.detached(priority: .userInitiated) {
                Result {
                    try BackupEngine.run(plan, isCancelled: { Task.isCancelled }) { index, _, file, _ in
                        Task { @MainActor in self.recordProgress(index: index, file: file) }
                    }
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
