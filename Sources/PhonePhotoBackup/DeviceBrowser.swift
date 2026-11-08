import AppKit
import BackupCore
import CryptoKit
@preconcurrency import ImageCaptureCore
import Observation
import os

/// Phones and cameras connected over USB, found with ImageCaptureCore: iPhone and iPad, and
/// Android phones in "Transfer photos (PTP)" mode. Reads each device's file list and downloads
/// single files for the backup engine. Never deletes or changes anything on the device.
@MainActor @Observable
final class DeviceBrowser: NSObject {
    struct Device: Identifiable, Equatable {
        let id: String
        var name: String
        var icon: NSImage?
        var state: State
    }

    enum State: Equatable {
        /// Connected; the session is opening.
        case connecting
        /// An iPhone or iPad that is locked or does not trust this Mac yet.
        case locked
        /// Reading the file list; `count` items found so far.
        case reading(count: Int)
        /// The complete file list is available.
        case ready(count: Int)
        case failed(String)
    }

    enum DeviceError: LocalizedError {
        case disconnected, notReady, fileMissing

        var errorDescription: String? {
            switch self {
            case .disconnected: String(localized: "The phone was disconnected. Reconnect it and try again.")
            case .notReady: String(localized: "The phone is not ready yet. Unlock it and try again.")
            case .fileMissing: String(localized: "The file is no longer on the phone.")
            }
        }
    }

    private static let log = Logger(subsystem: "io.github.jasonhuzhensheng.PhonePhotoBackup", category: "device")

    private(set) var devices: [Device] = []
    /// Called after a device appears or disappears, with its id.
    @ObservationIgnored var onDeviceAdded: ((String) -> Void)?
    @ObservationIgnored var onDeviceRemoved: ((String) -> Void)?

    @ObservationIgnored private let browser = ICDeviceBrowser()
    @ObservationIgnored private var cameras: [String: ICCameraDevice] = [:]
    /// Relative path → file, filled by `catalog(of:)` and used by `download`.
    @ObservationIgnored private var catalogs: [String: [String: ICCameraFile]] = [:]
    /// Devices with a session request in flight.
    @ObservationIgnored private var opening: Set<String> = []

    func device(_ id: String) -> Device? { devices.first { $0.id == id } }

    func start() {
        guard !browser.isBrowsing else { return }
        browser.delegate = self
        let mask = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        if let typeMask = ICDeviceTypeMask(rawValue: mask) {
            browser.browsedDeviceTypeMask = typeMask
        }
        browser.start()
    }

    // MARK: Reading the file list

    /// Waits until the device has delivered its complete file list. Throws when the device is
    /// disconnected, fails, or the calling task is cancelled.
    func waitUntilReady(_ id: String) async throws {
        var retried = false
        while true {
            guard let device = device(id), let camera = cameras[id] else { throw DeviceError.disconnected }
            switch device.state {
            case .ready:
                return
            case .failed(let message):
                // Try once more: a freshly trusted iPhone often needs a new session.
                guard !retried else { throw FailedError(message: message) }
                retried = true
                update(id) { $0.state = .connecting }
                openSession(camera)
            case .connecting:
                openSession(camera)
            case .locked, .reading:
                break
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Lists every file on the device with a relative path that mirrors its folders.
    func catalog(of id: String) throws -> (name: String, files: [PlannedFile]) {
        guard let camera = cameras[id] else { throw DeviceError.disconnected }
        guard case .ready = device(id)?.state else { throw DeviceError.notReady }
        var byPath: [String: ICCameraFile] = [:]
        var files: [PlannedFile] = []

        func add(_ file: ICCameraFile, _ folders: [String]) {
            let path = BackupEngine.devicePath(folders + [file.name ?? "_"])
            guard byPath[path] == nil else { return }
            byPath[path] = file
            files.append(PlannedFile(relativePath: path, size: Int64(file.fileSize)))
        }
        func visit(_ items: [ICCameraItem]?, _ folders: [String]) {
            for item in items ?? [] {
                if let folder = item as? ICCameraFolder {
                    visit(folder.contents, folders + [folder.name ?? "_"])
                } else if let file = item as? ICCameraFile {
                    add(file, folders)
                    // Live Photo videos and edit files (.AAE) can be attached to the main file.
                    for case let sidecar as ICCameraFile in file.sidecarFiles ?? [] {
                        add(sidecar, folders)
                    }
                }
            }
        }
        visit(camera.contents, [])
        catalogs[id] = byPath
        return (camera.name ?? String(localized: "Phone"), files)
    }

    // MARK: Review: hashing and thumbnails

    /// Every file in the last catalog, with its date and (for videos) length.
    func items(of id: String) -> [PhoneItem] {
        (catalogs[id] ?? [:]).map { path, file in
            PhoneItem(relativePath: path, size: Int64(file.fileSize), date: file.creationDate,
                      duration: file.duration > 0 ? file.duration : nil)
        }
    }

    /// SHA-256 of a file on the phone, read in chunks without saving it to disk.
    func sha256(deviceID: String, path: String) async throws -> String {
        let file = try await availableFile(deviceID: deviceID, path: path)
        let size = Int64(file.fileSize)
        var hasher = StreamingSHA256()
        var offset: Int64 = 0
        let chunk: Int64 = 8 << 20
        while offset < size {
            try Task.checkCancellation()
            let length = min(chunk, size - offset)
            let data = try await file.requestReadData(atOffset: off_t(offset), length: off_t(length))
            guard !data.isEmpty else { throw BackupError(.downloadIncomplete) }
            hasher.update(data)
            offset += Int64(data.count)
        }
        return hasher.finalize()
    }

    /// A small preview image of a file on the phone.
    func thumbnail(deviceID: String, path: String) async -> NSImage? {
        guard let file = catalogs[deviceID]?[path],
              let data = try? await file.requestThumbnailData(options: nil) else { return nil }
        return NSImage(data: data)
    }

    // MARK: Downloading

    /// Downloads one file into `directory` and returns its URL.
    ///
    /// An iPhone that auto-locks or is briefly unplugged drops its connection. Instead of failing,
    /// this waits until the phone is back and unlocked, rereads its file list and carries on.
    /// The wait ends only when the file arrives, the file is gone from the phone, or the task is
    /// cancelled (the Stop button).
    func download(deviceID: String, path: String, into directory: URL) async throws -> URL {
        var failures = 0
        while true {
            let file = try await availableFile(deviceID: deviceID, path: path)
            do {
                return try await requestDownload(file, path: path, into: directory)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Self.log.error("download failed for \(path, privacy: .private): \(error.localizedDescription, privacy: .public)")
                failures += 1
                // Give the delegate callbacks a moment to report a lock or disconnect.
                try await Task.sleep(for: .seconds(1.5))
                if failures < 5, !isUsable(deviceID) { continue }
                throw error
            }
        }
    }

    /// True while the device is connected, unlocked and has a current file list.
    func isUsable(_ id: String) -> Bool {
        guard let camera = cameras[id], !camera.isAccessRestrictedAppleDevice, catalogs[id] != nil,
              case .ready = device(id)?.state else { return false }
        return true
    }

    /// Waits until `path` can be downloaded from the device, rereading the file list if needed.
    private func availableFile(deviceID id: String, path: String) async throws -> ICCameraFile {
        var waitingSince: Date?
        while true {
            if let camera = cameras[id], !camera.isAccessRestrictedAppleDevice, case .ready = device(id)?.state {
                if catalogs[id] == nil { _ = try catalog(of: id) }
                guard let file = catalogs[id]?[path] else { throw DeviceError.fileMissing }
                if let waitingSince {
                    Self.log.info("device back after \(Date().timeIntervalSince(waitingSince), format: .fixed(precision: 1))s")
                }
                return file
            }
            if waitingSince == nil {
                waitingSince = Date()
                Self.log.info("waiting for the device to reconnect or unlock")
            }
            if let camera = cameras[id], case .connecting = device(id)?.state { openSession(camera) }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    private func requestDownload(_ file: ICCameraFile, path: String, into directory: URL) async throws -> URL {
        let ext = (path as NSString).pathExtension
        let name = UUID().uuidString.lowercased() + (ext.isEmpty ? "" : "." + ext)
        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: directory,
            .saveAsFilename: name,
            .overwrite: false,
        ]
        let once = ResumeOnce<URL>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.continuation = continuation
                let progress = file.requestDownload(options: options) { filename, error in
                    if let error {
                        once.resume(.failure(error))
                    } else {
                        let saved = filename ?? name
                        let url = saved.hasPrefix("/") ? URL(fileURLWithPath: saved)
                                                       : directory.appendingPathComponent(saved)
                        once.resume(.success(url))
                    }
                }
                once.progress = progress
                if progress == nil, !once.isFinished {
                    once.resume(.failure(DeviceError.notReady))
                }
            }
        } onCancel: {
            once.cancel()
        }
    }

    // MARK: Device bookkeeping (main thread)

    private static func identifier(_ device: ICDevice) -> String {
        device.uuidString ?? String(UInt(bitPattern: ObjectIdentifier(device).hashValue))
    }

    /// Asks the device to open a session unless one is open or already requested. Uses the
    /// delegate-based call; inside async code Swift would otherwise pick the async overload.
    private func openSession(_ device: ICDevice) {
        let id = Self.identifier(device)
        guard !device.hasOpenSession, !opening.contains(id) else { return }
        opening.insert(id)
        device.requestOpenSession()
    }

    private func update(_ id: String, _ change: (inout Device) -> Void) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        change(&devices[index])
    }

    private func added(_ camera: ICCameraDevice) {
        let id = Self.identifier(camera)
        Self.log.info("added \(camera.name ?? "?", privacy: .public) restricted=\(camera.isAccessRestrictedAppleDevice)")
        if let existing = cameras[id] {
            guard existing !== camera else { return }
            // The system re-announced the same phone with a new object: switch to it.
            existing.delegate = nil
            catalogs[id] = nil
            opening.remove(id)
        }
        cameras[id] = camera
        camera.delegate = self
        let icon = camera.icon.map { NSImage(cgImage: $0, size: .zero) }
        let state: State = camera.isAccessRestrictedAppleDevice ? .locked : .connecting
        if devices.contains(where: { $0.id == id }) {
            update(id) { $0.state = state; $0.icon = icon ?? $0.icon }
        } else {
            devices.append(Device(id: id, name: camera.name ?? String(localized: "Phone"), icon: icon, state: state))
        }
        // Back up originals (HEIC/HEVC), not JPEG/H.264 conversions.
        if camera.capabilities.contains(ICDeviceCapability.cameraDeviceSupportsHEIF.rawValue) {
            camera.mediaPresentation = .originalAssets
        }
        // Opening a session starts reading the file list (and shows "Trust this computer?" on iPhone).
        openSession(camera)
        onDeviceAdded?(id)
    }

    private func removed(_ device: ICDevice) {
        let id = Self.identifier(device)
        // Ignore a stale object for a phone that has already been re-announced.
        guard let current = cameras[id], current === device else { return }
        Self.log.info("removed \(device.name ?? "?", privacy: .public)")
        cameras[id] = nil
        catalogs[id] = nil
        opening.remove(id)
        devices.removeAll { $0.id == id }
        onDeviceRemoved?(id)
    }

    private func refresh(_ device: ICDevice, catalogComplete: Bool = false) {
        let id = Self.identifier(device)
        guard let camera = cameras[id] else { return }
        let count = camera.mediaFiles?.count ?? 0
        update(id) { entry in
            if camera.isAccessRestrictedAppleDevice {
                entry.state = .locked
            } else if catalogComplete {
                entry.state = .ready(count: count)
            } else if case .ready = entry.state {
                entry.state = .ready(count: count)
            } else if camera.hasOpenSession {
                entry.state = .reading(count: count)
            }
        }
    }

    private func failed(_ device: ICDevice, _ error: Error) {
        Self.log.error("device error: \(error.localizedDescription, privacy: .public)")
        opening.remove(Self.identifier(device))
        update(Self.identifier(device)) { $0.state = .failed(error.localizedDescription) }
    }

    private func sessionClosed(_ device: ICDevice) {
        let id = Self.identifier(device)
        guard cameras[id] === device else { return }
        Self.log.info("session closed")
        catalogs[id] = nil
        opening.remove(id)
        let locked = (device as? ICCameraDevice)?.isAccessRestrictedAppleDevice ?? false
        update(id) { $0.state = locked ? .locked : .connecting }
        // Reopen right away so the file list is fresh when it is needed.
        if !locked { openSession(device) }
    }

    private func renamed(_ device: ICDevice) {
        update(Self.identifier(device)) { $0.name = device.name ?? $0.name }
    }
}

/// Incremental SHA-256 for data read from the phone in pieces.
struct StreamingSHA256 {
    private var hasher = CryptoKit.SHA256()
    mutating func update(_ data: Data) { hasher.update(data: data) }
    func finalize() -> String { hasher.finalize().map { String(format: "%02x", $0) }.joined() }
}

private struct FailedError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Resumes a continuation exactly once, whether the download finishes or the task is cancelled.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    var continuation: CheckedContinuation<Value, Error>?
    var progress: Progress?

    var isFinished: Bool { lock.withLock { finished } }

    func resume(_ result: Result<Value, Error>) {
        let continuation: CheckedContinuation<Value, Error>? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    func cancel() {
        let progress = lock.withLock { self.progress }
        progress?.cancel()
        resume(.failure(CancellationError()))
    }
}

// MARK: - ImageCaptureCore delegates

/// ImageCaptureCore calls its delegates on the main thread on macOS; hop there if it ever does not.
private func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        DispatchQueue.main.async(execute: body)
    }
}

extension DeviceBrowser: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        onMain { self.added(camera) }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        onMain { self.removed(device) }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, deviceDidChangeName device: ICDevice) {
        onMain { self.renamed(device) }
    }
}

extension DeviceBrowser: ICCameraDeviceDelegate {
    nonisolated func didRemove(_ device: ICDevice) {
        onMain { self.removed(device) }
    }

    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        onMain {
            if let error {
                self.failed(device, error)
            } else {
                self.opening.remove(Self.identifier(device))
                self.refresh(device)
            }
        }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        onMain { self.sessionClosed(device) }
    }

    nonisolated func device(_ device: ICDevice, didEncounterError error: (any Error)?) {
        guard let error else { return }
        onMain { self.failed(device, error) }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        onMain { self.refresh(camera) }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        onMain { self.refresh(camera) }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?,
                                  for item: ICCameraItem, error: (any Error)?) {}

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?,
                                  for item: ICCameraItem, error: (any Error)?) {}

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}

    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}

    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        onMain { self.refresh(device, catalogComplete: true) }
    }

    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        onMain {
            // Unlocked and trusted. Start a fresh session so the complete file list is read again;
            // file objects from before the lock may no longer work.
            Self.log.info("access restriction removed")
            let id = Self.identifier(device)
            self.catalogs[id] = nil
            self.update(id) { $0.state = .connecting }
            if device.hasOpenSession {
                device.requestCloseSession() // didCloseSession reopens it
            } else {
                self.openSession(device)
            }
        }
    }

    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        onMain {
            Self.log.info("access restriction enabled (phone locked)")
            self.catalogs[Self.identifier(device)] = nil
            self.refresh(device)
        }
    }
}
