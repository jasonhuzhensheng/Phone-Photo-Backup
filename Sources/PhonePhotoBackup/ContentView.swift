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
                    FolderRow(title: "Source folder", placeholder: "Folder exported from your phone",
                              systemImage: "iphone", url: model.sourceURL, disabled: model.isBusy,
                              choose: model.chooseSource, drop: model.setSource)
                    Divider().padding(.vertical, 8)
                    FolderRow(title: "Backup location", placeholder: "A separate folder or external drive",
                              systemImage: "externaldrive", url: model.destinationURL, disabled: model.isBusy,
                              choose: model.chooseDestination, drop: model.setDestination)
                }
                .padding(6)
            }
            StatusPanel()
                .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            actions
        }
        .padding(24)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 440)
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
                Text("\(plan.files.count.formatted()) files, \(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file)), will be copied into:\n\(plan.backupDirectory.path)\n\nOriginal files will not be changed or deleted.")
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
            case .backingUp:
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
                        Text("Scanning source files…")
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
            Label("Export photos from your phone to a folder on this Mac first.", systemImage: "1.circle")
            Label("Choose that folder and a separate backup location — or drag folders onto the rows above.", systemImage: "2.circle")
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
