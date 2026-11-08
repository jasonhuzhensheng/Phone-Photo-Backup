import AppKit
import BackupCore
import SwiftUI

struct ContentView: View {
    @Environment(BackupModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            header
            GroupBox {
                VStack(spacing: 0) {
                    SourceRow()
                    Divider().padding(.vertical, 8)
                    FolderRow(title: "Backup location", placeholder: "A separate folder or external drive",
                              systemImage: "externaldrive", url: model.destinationURL, disabled: model.isBusy,
                              choose: model.chooseDestination, drop: model.setDestination)
                }
                .padding(6)
            }
            options
            StatusPanel()
                .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            actions
        }
        .padding(24)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 540)
        .task {
            SelfCheck.runIfRequested(model: model) { openWindow(id: BackupVideosView.windowID) }
        }
        .alert("Backup error", isPresented: Binding(get: { model.alertMessage != nil },
                                                   set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: model.alertMessage ?? "")
        }
        .confirmationDialog("Start backup?", isPresented: $model.confirmingStart) {
            Button("Start Backup") { model.startBackup() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let plan = model.plan {
                let size = ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file)
                if model.importToPhotos {
                    Text("\(plan.files.count.formatted()) files, \(size), will be copied into:\n\(plan.backupDirectory.path)\n\nOriginal files will not be changed or deleted. Afterwards, photos and videos that are not in Photos yet will be imported.")
                } else {
                    Text("\(plan.files.count.formatted()) files, \(size), will be copied into:\n\(plan.backupDirectory.path)\n\nOriginal files will not be changed or deleted.")
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { model.review != nil },
            set: { if !$0 { model.closeReview() } }
        )) {
            if let review = model.review {
                ReviewSheet(review: review).environment(model)
            }
        }
        .confirmationDialog("Import into Photos?", isPresented: Binding(
            get: { model.confirmingImport },
            set: { if !$0, model.confirmingImport { model.answerImport(false) } }
        )) {
            Button("Import") { model.answerImport(true) }
            Button("Cancel", role: .cancel) { model.answerImport(false) }
        } message: {
            if let pending = model.pendingImport {
                Text("Up to \(pending.count.formatted()) photos and videos (\(ByteCountFormatter.string(fromByteCount: pending.bytes, countStyle: .file))) will be added to Photos, in the album “\(PhotoLibraryImporter.albumName)”. Items already in Photos are skipped. With iCloud Photos turned on, they sync to your other devices.")
            }
        }
    }

    private var options: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 6) {
            Toggle("Import into Photos after each backup (iCloud Photos then syncs them to your other devices)",
                   isOn: $model.importToPhotos)
            Toggle("Before backing up a phone, list the largest videos and duplicates to delete", isOn: $model.reviewBeforeBackup)
            Toggle("Start automatically when a phone is connected (skips the list)", isOn: $model.autoStart)
        }
        .toggleStyle(.checkbox)
        .disabled(model.isBusy)
        .padding(.horizontal, 4)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "photo.stack.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
                .frame(width: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text("Phone Photo Backup").font(.title2.weight(.semibold))
                Text("Copies every file and verifies it with SHA-256. Originals are never changed or deleted; re-running skips unchanged files.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actions: some View {
        HStack {
            Group {
                if model.importToPhotos {
                    Label("Backups stay on this Mac. Photos syncs imports through your own iCloud Photos.", systemImage: "lock.shield")
                } else {
                    Label("Everything stays on this Mac. No cloud upload.", systemImage: "lock.shield")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            Spacer()
            switch model.phase {
            case .backingUp, .scanning, .importing:
                Button("Stop", role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
            default:
                OpenBackupVideosButton()
                Button("Import into Photos") { model.importAllBackups() }
                    .disabled(!model.canImport)
                    .help("Add all backups in the backup location to Photos, skipping duplicates")
                Button("Scan Source") { model.scan() }
                    .disabled(!model.canScan)
                    .keyboardShortcut(model.canStart ? nil : .defaultAction)
                Button("Start Backup") { model.requestStart() }
                    .disabled(!model.canStart)
                    .keyboardShortcut(model.canStart ? .defaultAction : nil)
            }
        }
        .controlSize(.large)
    }
}

// MARK: - Source row

/// The source: a connected phone (picked from a menu) or a folder (picked or dropped).
private struct SourceRow: View {
    @Environment(BackupModel.self) private var model
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Source").font(.headline)
                subtitle
            }
            Spacer(minLength: 8)
            Menu {
                if model.devices.devices.isEmpty {
                    Text("No phone connected")
                }
                ForEach(model.devices.devices) { device in
                    Button {
                        model.setSourceDevice(device.id)
                    } label: {
                        Label(device.name, systemImage: "iphone")
                    }
                }
                Divider()
                Button("Folder…", action: model.chooseSource)
            } label: {
                Text(model.source == nil ? LocalizedStringKey("Choose…") : LocalizedStringKey("Change…"))
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(model.isBusy)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(targeted ? Color.accentColor.opacity(0.15) : .clear))
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isBusy, let folder = urls.first(where: \.hasDirectoryPath) ?? urls.first.flatMap(folderURL) else { return false }
            model.setSource(folder)
            return true
        } isTargeted: { targeted = $0 }
    }

    @ViewBuilder private var icon: some View {
        switch model.source {
        case .folder(let url):
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        case .device:
            if let image = model.sourceDevice?.icon {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "iphone").font(.title2).foregroundStyle(.tint)
            }
        case nil:
            Image(systemName: "iphone").font(.title2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var subtitle: some View {
        switch model.source {
        case .folder(let url):
            Text(verbatim: url.path)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(url.path)
        case .device:
            if let device = model.sourceDevice {
                HStack(spacing: 6) {
                    Text(verbatim: device.name).font(.callout)
                    DeviceStatus(state: device.state)
                }
                .lineLimit(1)
            } else {
                Text("Phone not connected").font(.callout).foregroundStyle(.orange)
            }
        case nil:
            Text("Connect your phone with a USB cable, or choose an exported folder")
                .font(.callout).foregroundStyle(.tertiary)
        }
    }

    private func folderURL(_ url: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return url
    }
}

/// One-line status of a connected phone.
struct DeviceStatus: View {
    let state: DeviceBrowser.State

    var body: some View {
        switch state {
        case .connecting:
            Text("· Connecting…").font(.callout).foregroundStyle(.secondary)
        case .locked:
            Text("· Unlock the phone and tap “Trust”").font(.callout).foregroundStyle(.orange)
        case .reading(let count):
            Text("· Reading file list… \(count.formatted()) items").font(.callout).foregroundStyle(.secondary)
        case .ready(let count):
            Text("· \(count.formatted()) items").font(.callout).foregroundStyle(.secondary)
        case .failed(let message):
            Text(verbatim: "· " + message).font(.callout).foregroundStyle(.red).help(message)
        }
    }
}

// MARK: - Folder row

private struct FolderRow: View {
    let title: LocalizedStringKey
    let placeholder: LocalizedStringKey
    let systemImage: String
    let url: URL?
    let disabled: Bool
    let choose: () -> Void
    let drop: (URL) -> Void
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                } else {
                    Image(systemName: systemImage).font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let url {
                    Text(verbatim: url.path)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(url.path)
                } else {
                    Text(placeholder).font(.callout).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Button(url == nil ? LocalizedStringKey("Choose…") : LocalizedStringKey("Change…"), action: choose)
                .disabled(disabled)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(targeted ? Color.accentColor.opacity(0.15) : .clear))
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            guard !disabled, let folder = urls.first(where: \.hasDirectoryPath) ?? urls.first.flatMap(Self.folderURL) else { return false }
            drop(folder)
            return true
        } isTargeted: { targeted = $0 }
    }

    private static func folderURL(_ url: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return url
    }
}

// MARK: - Status

private struct StatusPanel: View {
    @Environment(BackupModel.self) private var model

    var body: some View {
        GroupBox {
            Group {
                switch model.phase {
                case .idle:
                    hint
                case .scanning:
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        if let device = model.sourceDevice {
                            Text("Reading the file list from \(device.name)…")
                            DeviceStatus(state: device.state)
                        } else {
                            Text("Scanning source files…")
                        }
                    }
                case .ready:
                    if let plan = model.plan { PlanSummary(plan: plan) }
                case .backingUp:
                    progress
                case .deleting:
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Moving the selected items to Recently Deleted in Photos…")
                    }
                case .importing:
                    importProgress
                case .finished:
                    VStack(alignment: .leading, spacing: 14) {
                        if let report = model.report { ReportSummary(report: report) }
                        if let deletion = model.deletionReport { DeletionSummary(result: deletion) }
                        if let result = model.importReport { ImportSummary(result: result) }
                        if model.autoStart, case .device = model.source {
                            Label("Done. You can unplug this phone and connect the next one.", systemImage: "arrow.triangle.2.circlepath")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var hint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Connect your phone with a USB cable and unlock it. On iPhone tap “Trust”; on Android choose “Transfer photos (PTP)”.", systemImage: "1.circle")
            Label("Choose the phone (or a folder exported from it) and a separate backup location.", systemImage: "2.circle")
            Label("Scan to review the file count and size, then start the backup.", systemImage: "3.circle")
        }
        .foregroundStyle(.secondary)
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: model.fractionComplete)
            HStack {
                Text("\(model.processedFiles.formatted()) of \((model.plan?.files.count ?? 0).formatted()) files")
                Spacer()
                Text(verbatim: model.fractionComplete.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
            }
            .font(.callout)
            Text(verbatim: model.currentFile)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if case .device = model.source {
                deviceNotice
            }
        }
    }

    @ViewBuilder private var importProgress: some View {
        switch model.importStage {
        case .preparing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Finding photos and videos to import…")
            }
        case .checkingLibrary:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking which photos are already in Photos…")
            }
        case .importing:
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: model.fractionComplete)
                HStack {
                    Text("Importing into Photos: \(model.importDone.formatted()) of \(model.importTotal.formatted())")
                    Spacer()
                    Text(verbatim: model.fractionComplete.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                }
                .font(.callout)
                Text(verbatim: model.currentFile)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder private var deviceNotice: some View {
        if let device = model.sourceDevice {
            switch device.state {
            case .ready:
                Label("Keep the phone unlocked and connected until the backup finishes.", systemImage: "iphone")
                    .font(.caption).foregroundStyle(.secondary)
            case .locked:
                Label("Paused: the phone is locked. Unlock it to continue.", systemImage: "lock.iphone")
                    .font(.caption).foregroundStyle(.orange)
            default:
                Label("Paused: reconnecting to the phone…", systemImage: "iphone.radiowaves.left.and.right")
                    .font(.caption).foregroundStyle(.orange)
            }
        } else {
            Label("Paused: the phone was disconnected. Reconnect and unlock it to continue.", systemImage: "cable.connector.slash")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}

private struct PlanSummary: View {
    let plan: BackupPlan

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                Text("Files").foregroundStyle(.secondary)
                Text(verbatim: plan.files.count.formatted()).monospacedDigit()
            }
            GridRow {
                Text("Size").foregroundStyle(.secondary)
                Text(verbatim: ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file))
            }
            GridRow {
                Text("Backup folder").foregroundStyle(.secondary)
                Text(verbatim: plan.backupDirectory.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct DeletionSummary: View {
    @State private var showDetails = false
    let result: BackupModel.DeletionReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("\(result.deleted.formatted()) of \(result.requested.formatted()) selected items moved to Recently Deleted in Photos")
                    .font(.headline)
            } icon: {
                Image(systemName: "trash").foregroundStyle(result.deleted == result.requested ? .green : .orange)
            }
            if let error = result.error {
                Text(verbatim: error).font(.callout).foregroundStyle(.red)
            }
            if !result.notBackedUp.isEmpty || !result.notInPhotos.isEmpty {
                DisclosureGroup("Show items that were not deleted", isExpanded: $showDetails) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            if !result.notBackedUp.isEmpty {
                                Text("No verified backup copy:").font(.caption.weight(.semibold))
                                Text(verbatim: result.notBackedUp.joined(separator: "\n")).font(.caption.monospaced())
                            }
                            if !result.notInPhotos.isEmpty {
                                Text("Not found in Photos (delete these on the phone yourself):").font(.caption.weight(.semibold))
                                Text(verbatim: result.notInPhotos.joined(separator: "\n")).font(.caption.monospaced())
                            }
                        }
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }
        }
    }
}

private struct ImportSummary: View {
    @State private var showErrors = false
    let result: BackupModel.ImportReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(title).font(.headline)
            } icon: {
                Image(systemName: icon).foregroundStyle(color)
            }
            HStack(spacing: 24) {
                stat("Imported", result.imported)
                stat("Already in Photos", result.alreadyInPhotos + result.previouslyImported)
                stat("Duplicates skipped", result.duplicates)
                stat("Errors", result.errors.count)
                Spacer()
            }
            if !result.errors.isEmpty {
                DisclosureGroup("Show errors", isExpanded: $showErrors) {
                    ScrollView {
                        Text(verbatim: result.errors.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }
        }
    }

    private var title: LocalizedStringKey {
        if result.cancelled { return "Import stopped. Run it again to continue." }
        return result.errors.isEmpty ? "Imported into Photos" : "Import finished with errors"
    }

    private var icon: String {
        result.cancelled ? "pause.circle.fill" : result.errors.isEmpty ? "photo.on.rectangle.angled" : "exclamationmark.triangle.fill"
    }

    private var color: Color {
        result.cancelled ? .secondary : result.errors.isEmpty ? .green : .orange
    }

    private func stat(_ label: LocalizedStringKey, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value.formatted()).font(.title3.monospacedDigit())
        }
    }
}

private struct ReportSummary: View {
    @Environment(BackupModel.self) private var model
    @State private var showErrors = false
    let report: BackupReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(title).font(.headline)
            } icon: {
                Image(systemName: icon).foregroundStyle(color)
            }
            HStack(spacing: 24) {
                stat("Copied", report.copied.formatted())
                stat("Unchanged", report.unchanged.formatted())
                stat("Errors", report.errors.count.formatted())
                stat("Data copied", ByteCountFormatter.string(fromByteCount: report.bytesCopied, countStyle: .file))
                Spacer()
                Button("Show in Finder") { model.revealBackupFolder() }
            }
            if !report.errors.isEmpty {
                DisclosureGroup("Show errors", isExpanded: $showErrors) {
                    ScrollView {
                        Text(verbatim: report.errors.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }
        }
    }

    private var title: LocalizedStringKey {
        if report.cancelled { return "Backup stopped. Run it again to continue." }
        return report.errors.isEmpty ? "Backup complete" : "Backup finished with errors"
    }

    private var icon: String {
        report.cancelled ? "pause.circle.fill" : report.errors.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var color: Color {
        report.cancelled ? .secondary : report.errors.isEmpty ? .green : .orange
    }

    private func stat(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value).font(.title3.monospacedDigit())
        }
    }
}
