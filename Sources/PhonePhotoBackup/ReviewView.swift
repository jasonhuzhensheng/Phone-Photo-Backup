import AppKit
import BackupCore
import Observation
import SwiftUI

/// The step before a phone backup: lists the largest videos and exact duplicates so the user can
/// pick what to delete. Deleting happens later, through Photos, so items go to Recently Deleted.
@MainActor @Observable
final class ReviewSession {
    enum Stage: Equatable {
        case hashing(done: Int, total: Int)
        case ready
        case failed(String)
    }

    let deviceID: String
    private(set) var stage = Stage.hashing(done: 0, total: 0)
    private(set) var largeVideos: [PhoneItem] = []
    private(set) var duplicates: [DuplicateGroup] = []
    var selected: Set<String> = []
    /// Also keep a backup copy of the selected items (recommended).
    var backUpSelected = true
    private(set) var thumbnails: [String: NSImage] = [:]
    @ObservationIgnored private var items: [String: PhoneItem] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var requestedThumbnails: Set<String> = []

    init(deviceID: String) { self.deviceID = deviceID }

    var selectedItems: [PhoneItem] { selected.compactMap { items[$0] }.sorted { $0.relativePath < $1.relativePath } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    func start(devices: DeviceBrowser) {
        let all = devices.items(of: deviceID)
        items = Dictionary(uniqueKeysWithValues: all.map { ($0.relativePath, $0) })
        largeVideos = PhoneReview.largestVideos(all)
        let id = deviceID
        task = Task {
            do {
                let groups = try await PhoneReview.findDuplicates(all, hash: { item in
                    try await devices.sha256(deviceID: id, path: item.relativePath)
                }, progress: { done, total in
                    Task { @MainActor in self.stage = .hashing(done: done, total: total) }
                })
                await Task.yield()
                duplicates = groups
                // Suggest deleting every copy except the oldest; nothing else is pre-selected.
                selected.formUnion(groups.flatMap { $0.extras.map(\.relativePath) })
                stage = .ready
            } catch is CancellationError {
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() { task?.cancel() }

    func loadThumbnail(_ path: String, devices: DeviceBrowser) {
        guard requestedThumbnails.insert(path).inserted else { return }
        Task {
            if let image = await devices.thumbnail(deviceID: deviceID, path: path) {
                thumbnails[path] = image
            }
        }
    }

    func isWholeGroupSelected(_ group: DuplicateGroup) -> Bool {
        group.files.allSatisfy { selected.contains($0.relativePath) }
    }
}

struct ReviewSheet: View {
    @Environment(BackupModel.self) private var model
    @Bindable var review: ReviewSession
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review before backup").font(.title2.weight(.semibold))
                Text("Pick what to delete. After the backup, the selected items are deleted in Photos and go to Recently Deleted, where they can be recovered for 30 days. iCloud Photos then removes them from the phone too.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            List {
                Section {
                    if review.largeVideos.isEmpty {
                        Text("No videos larger than 50 MB.").foregroundStyle(.secondary)
                    }
                    ForEach(review.largeVideos) { item in
                        ItemRow(item: item, review: review, note: nil)
                    }
                } header: {
                    Text("Largest videos")
                }

                Section {
                    switch review.stage {
                    case .hashing(let done, let total):
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Looking for duplicates… \(done.formatted()) of \(total.formatted())")
                                .foregroundStyle(.secondary)
                        }
                    case .failed(let message):
                        Text(verbatim: message).foregroundStyle(.red)
                    case .ready:
                        if review.duplicates.isEmpty {
                            Text("No duplicates found.").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(review.duplicates) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(group.files.enumerated()), id: \.element.id) { index, item in
                                ItemRow(item: item, review: review, note: index == 0 ? "Oldest copy" : nil)
                            }
                            if review.isWholeGroupSelected(group) {
                                Label("Every copy in this group is selected.", systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Exact duplicates")
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 320)

            Toggle("Also back up the selected items (recommended)", isOn: $review.backUpSelected)
                .toggleStyle(.checkbox)

            HStack {
                Text("Selected: \(review.selected.count.formatted()) items, \(ByteCountFormatter.string(fromByteCount: review.selectedBytes, countStyle: .file))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { model.closeReview() }
                    .keyboardShortcut(.cancelAction)
                Button("Back Up Without Deleting") { model.finishReview(delete: false) }
                Button("Back Up, Then Delete Selected") { confirmingDelete = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(review.selected.isEmpty || review.stage != .ready)
            }
        }
        .padding(20)
        .frame(minWidth: 720, idealWidth: 760, minHeight: 600)
        .confirmationDialog("Delete the selected items?", isPresented: $confirmingDelete) {
            Button("Back Up, Then Delete", role: .destructive) { model.finishReview(delete: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            if review.backUpSelected {
                Text("\(review.selected.count.formatted()) items (\(ByteCountFormatter.string(fromByteCount: review.selectedBytes, countStyle: .file))) will be backed up first. Only items with a verified backup copy are then moved to Recently Deleted in Photos. Items not found in Photos are left alone.")
            } else {
                Text("\(review.selected.count.formatted()) items (\(ByteCountFormatter.string(fromByteCount: review.selectedBytes, countStyle: .file))) will NOT be backed up. They are moved to Recently Deleted in Photos and can be recovered there for 30 days only. Items not found in Photos are left alone.")
            }
        }
    }
}

private struct ItemRow: View {
    @Environment(BackupModel.self) private var model
    let item: PhoneItem
    @Bindable var review: ReviewSession
    let note: LocalizedStringKey?

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { review.selected.contains(item.relativePath) },
                set: { if $0 { review.selected.insert(item.relativePath) } else { review.selected.remove(item.relativePath) } }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            Group {
                if let image = review.thumbnails[item.relativePath] {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: item.isVideo ? "video" : "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
            .onAppear { review.loadThumbnail(item.relativePath, devices: model.devices) }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: item.filename).font(.callout)
                    if let note {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(verbatim: details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(verbatim: ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                .font(.callout.monospacedDigit())
        }
    }

    private var details: String {
        var parts: [String] = []
        if let date = item.date { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
        if let duration = item.duration {
            parts.append(Duration.seconds(duration).formatted(.time(pattern: duration >= 3600 ? .hourMinuteSecond : .minuteSecond)))
        }
        parts.append((item.relativePath as NSString).deletingLastPathComponent)
        return parts.joined(separator: " · ")
    }
}
