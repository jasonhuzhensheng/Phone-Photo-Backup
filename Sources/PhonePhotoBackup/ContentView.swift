import AppKit
import BackupCore
import SwiftUI

struct ContentView: View {
    @Environment(BackupModel.self) private var model

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
                    Divider().padding(.vertical, 8)
                    ReferenceRow()
                }
                .padding(6)
            }
            StatusPanel()
                .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            actions
        }
        .padding(24)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 540)
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
                let dup = plan.likelyDuplicates
                if dup.count > 0 {
                    Text("\(plan.files.count.formatted()) files, \(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file)), will be copied into:\n\(plan.backupDirectory.path)\n\nAbout \(dup.count.formatted()) of them (\(ByteCountFormatter.string(fromByteCount: dup.bytes, countStyle: .file))) are already in other backups on this drive and will not be stored again.\n\nOriginal files will not be changed or deleted.")
                } else {
                    Text("\(plan.files.count.formatted()) files, \(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file)), will be copied into:\n\(plan.backupDirectory.path)\n\nOriginal files will not be changed or deleted.")
                }
            }
        }
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
            Label("Everything stays on this Mac. No cloud upload.", systemImage: "lock.shield")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            switch model.phase {
            case .backingUp, .scanning:
                Button("Stop", role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
            default:
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

/// Folders that are already backed up elsewhere; files found there are not backed up again.
private struct ReferenceRow: View {
    @Environment(BackupModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text("Compare with").font(.headline)
                if model.referenceFolders.isEmpty {
                    Text("Optional: folders already backed up (another drive, an older backup). Files found there are not backed up again. Other backups on the backup drive are always compared.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(model.referenceFolders, id: \.self) { url in
                        HStack(spacing: 6) {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(verbatim: url.path)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(url.path)
                            Button {
                                model.removeReferenceFolder(url)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help(Text("Remove"))
                            .disabled(model.isBusy)
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            Button("Add…") { model.addReferenceFolders() }
                .disabled(model.isBusy)
        }
        .padding(6)
    }
}

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
                case .finished:
                    if let report = model.report { ReportSummary(report: report) }
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
    @Environment(BackupModel.self) private var model
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
            if !plan.existing.isEmpty {
                let dup = plan.likelyDuplicates
                GridRow {
                    Text("Already backed up").foregroundStyle(.secondary)
                    Text("\(dup.count.formatted()) files · \(Self.bytes(dup.bytes))").monospacedDigit()
                }
                GridRow {
                    Text("New").foregroundStyle(.secondary)
                    Text("\((plan.files.count - dup.count).formatted()) files · \(Self.bytes(plan.totalBytes - dup.bytes))")
                        .monospacedDigit()
                        .fontWeight(.semibold)
                }
            }
            if let free = model.freeSpace {
                // Estimate: new files by name and size. Exact duplicates found during the backup
                // make the real amount smaller.
                let needed = plan.totalBytes - plan.likelyDuplicates.bytes
                GridRow {
                    Text("Free on drive").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(verbatim: Self.bytes(free)).monospacedDigit()
                        if needed > free {
                            Label("Not enough space for about \(Self.bytes(needed)) of new files", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            GridRow {
                Text("Backup folder").foregroundStyle(.secondary)
                Text(verbatim: plan.backupDirectory.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if !plan.existing.isEmpty {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text("Compared with \(plan.existing.folders.joined(separator: ", ")) by name and size. During the backup every file is checked with SHA-256; files already stored there are not stored again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
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
                if report.duplicates > 0 {
                    stat("Duplicates skipped", report.duplicates.formatted())
                }
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
