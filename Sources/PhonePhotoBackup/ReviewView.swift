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

    /// Every listed item once, in list order: the largest videos, then the duplicates.
    var previewItems: [PhoneItem] {
        var seen: Set<String> = []
        return (largeVideos + duplicates.flatMap(\.files)).filter { seen.insert($0.relativePath).inserted }
    }

    func isWholeGroupSelected(_ group: DuplicateGroup) -> Bool {
        group.files.allSatisfy { selected.contains($0.relativePath) }
    }
}

/// The item a preview opens on.
struct PreviewTarget: Identifiable {
    let id: String
}

struct ReviewSheet: View {
    @Environment(BackupModel.self) private var model
    @Bindable var review: ReviewSession
    @State private var confirmingDelete = false
    @State private var previewing: PreviewTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review before backup").font(.title2.weight(.semibold))
                Text("Click a picture to watch the video or see the photo full size. Pick what to delete. After the backup, the selected items are deleted in Photos and go to Recently Deleted, where they can be recovered for 30 days. iCloud Photos then removes them from the phone too.")
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
                        ItemRow(item: item, review: review, note: nil, preview: preview)
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
                                ItemRow(item: item, review: review, note: index == 0 ? "Oldest copy" : nil, preview: preview)
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
        .frame(minWidth: 760, idealWidth: 860, minHeight: 640)
        .sheet(item: $previewing) { target in
            let entries = review.previewItems.map {
                PreviewEntry(id: $0.relativePath, filename: $0.filename, size: $0.size,
                             details: $0.reviewDetails, isVideo: $0.isVideo, fileURL: nil)
            }
            MediaPreviewSheet(entries: entries,
                              index: entries.firstIndex { $0.id == target.id } ?? 0,
                              marked: $review.selected,
                              phone: PreviewPhone(deviceID: review.deviceID,
                                                  backupDirectory: model.plan?.backupDirectory))
                .environment(model)
        }
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

    private func preview(_ item: PhoneItem) {
        previewing = PreviewTarget(id: item.relativePath)
    }
}

private struct ItemRow: View {
    @Environment(BackupModel.self) private var model
    let item: PhoneItem
    @Bindable var review: ReviewSession
    let note: LocalizedStringKey?
    let preview: (PhoneItem) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { review.selected.contains(item.relativePath) },
                set: { if $0 { review.selected.insert(item.relativePath) } else { review.selected.remove(item.relativePath) } }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            Button { preview(item) } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    if let image = review.thumbnails[item.relativePath] {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: item.isVideo ? "video" : "photo")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    if item.isVideo {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 30))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.45))
                    }
                }
                .frame(width: 160, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.isVideo ? "Play this video" : "Show this photo full size")
            .onAppear { review.loadThumbnail(item.relativePath, devices: model.devices) }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: item.filename).font(.body.weight(.medium))
                    if let note {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(verbatim: item.reviewDetails)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(verbatim: ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                .font(.body.monospacedDigit())
        }
        .padding(.vertical, 2)
    }
}
