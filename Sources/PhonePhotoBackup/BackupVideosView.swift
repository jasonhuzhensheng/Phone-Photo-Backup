import AppKit
import AVFoundation
import BackupCore
import Observation
import QuickLookThumbnailing
import SwiftUI

/// The videos in the backup location, largest first, by folder. Videos can be previewed and
/// moved to the Trash (never deleted outright).
@MainActor @Observable
final class BackupVideoBrowser {
    enum Stage: Equatable {
        case idle
        case scanning
        case ready
        case failed(String)
    }

    enum Order: String, CaseIterable, Identifiable {
        case size, date, name
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .size: "Size"
            case .date: "Date"
            case .name: "Name"
            }
        }
    }

    private(set) var root: URL?
    private(set) var stage = Stage.idle
    private(set) var videos: [BackupVideo] = [] { didSet { refresh() } }
    var showLivePhotoVideos = false { didSet { refresh() } }
    /// The folder shown on the right ("" for everything).
    var folder: String? = "" { didSet { refresh() } }
    var order = Order.size { didSet { refresh() } }
    /// Videos marked to be moved to the Trash, by relative path.
    var marked: Set<String> = []
    private(set) var tree: VideoFolder?
    private(set) var listed: [BackupVideo] = []
    private(set) var thumbnails: [String: NSImage] = [:]
    private(set) var durations: [String: Double] = [:]
    private(set) var trashResult: (count: Int, bytes: Int64, errors: [String])?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var requested: Set<String> = []

    var markedVideos: [BackupVideo] { videos.filter { marked.contains($0.id) } }
    var markedBytes: Int64 { markedVideos.reduce(0) { $0 + $1.size } }
    var listedBytes: Int64 { listed.reduce(0) { $0 + $1.size } }

    func scan(_ root: URL) {
        task?.cancel()
        self.root = root
        stage = .scanning
        marked = []
        trashResult = nil
        task = Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try BackupVideos.scan(root) }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let found):
                videos = found
                let paths = Set(found.map(\.folder))
                if let folder, !folder.isEmpty, !paths.contains(where: { $0 == folder || $0.hasPrefix(folder + "/") }) {
                    self.folder = ""
                }
                stage = .ready
            case .failure(let error):
                videos = []
                stage = .failed(error.localizedDescription)
            }
        }
    }

    func rescan() {
        if let root { scan(root) }
    }

    /// Thumbnail and length of a video, loaded when its row first appears.
    func loadDetails(_ video: BackupVideo) {
        guard requested.insert(video.id).inserted else { return }
        let url = video.url
        let id = video.id
        Task {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 160, height: 90),
                                                       scale: 2, representationTypes: .thumbnail)
            if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                thumbnails[id] = representation.nsImage
            }
            if let duration = try? await AVURLAsset(url: url).load(.duration), duration.seconds.isFinite {
                durations[id] = duration.seconds
            }
        }
    }

    func details(of video: BackupVideo) -> String {
        var parts: [String] = []
        if let date = video.date { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
        if let duration = durations[video.id], duration > 0 {
            parts.append(Duration.seconds(duration).formatted(.time(pattern: duration >= 3600 ? .hourMinuteSecond : .minuteSecond)))
        }
        if !video.folder.isEmpty { parts.append(video.folder) }
        return parts.joined(separator: " · ")
    }

    /// Moves the marked videos to the Trash, where they can be put back until it is emptied.
    func moveMarkedToTrash() {
        var gone: Set<String> = []
        var bytes: Int64 = 0
        var errors: [String] = []
        for video in markedVideos {
            do {
                try FileManager.default.trashItem(at: video.url, resultingItemURL: nil)
                gone.insert(video.id)
                bytes += video.size
            } catch {
                errors.append("\(video.relativePath): \(error.localizedDescription)")
            }
        }
        marked.subtract(gone)
        videos.removeAll { gone.contains($0.id) }
        trashResult = (gone.count, bytes, errors)
    }

    private func refresh() {
        let included = showLivePhotoVideos ? videos : videos.filter { !$0.isLivePhotoVideo }
        tree = root.map { BackupVideos.folderTree(included, rootName: $0.lastPathComponent) }
        var list = BackupVideos.videos(included, in: folder ?? "")
        switch order {
        case .size:
            list.sort { $0.size == $1.size ? $0.relativePath < $1.relativePath : $0.size > $1.size }
        case .date:
            list.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        case .name:
            list.sort { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        }
        listed = list
    }
}

struct BackupVideosView: View {
    @Environment(BackupModel.self) private var model
    @State private var browser = BackupVideoBrowser()
    @State private var previewing: PreviewTarget?
    @State private var confirmingTrash = false
    @State private var showingTrashErrors = false

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 420)
        } detail: {
            detail
        }
        .frame(minWidth: 900, minHeight: 560)
        .navigationTitle(Text("Backup Videos"))
        .toolbar {
            ToolbarItemGroup {
                Picker("Sort by", selection: $browser.order) {
                    ForEach(BackupVideoBrowser.Order.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Sort by")
                Toggle("Live Photo videos", isOn: $browser.showLivePhotoVideos)
                    .toggleStyle(.checkbox)
                    .help("Also list the short videos that belong to Live Photos")
                Button { browser.rescan() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Look for videos again")
                    .disabled(browser.stage == .scanning)
            }
        }
        .task(id: model.destinationURL) {
            if let url = model.destinationURL { browser.scan(url) }
        }
        .sheet(item: $previewing) { target in
            let entries = browser.listed.map {
                PreviewEntry(id: $0.id, filename: $0.filename, size: $0.size,
                             details: browser.details(of: $0), isVideo: true, fileURL: $0.url)
            }
            MediaPreviewSheet(entries: entries,
                              index: entries.firstIndex { $0.id == target.id } ?? 0,
                              marked: $browser.marked,
                              markedText: "Will be moved to the Trash")
                .environment(model)
        }
        .confirmationDialog("Move the marked videos to the Trash?", isPresented: $confirmingTrash) {
            Button("Move to Trash", role: .destructive) { browser.moveMarkedToTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(browser.marked.count.formatted()) videos (\(bytes(browser.markedBytes))) will be moved to the Trash. You can put them back until you empty the Trash. A video that is still on a phone is copied again by that phone's next backup; videos already imported into Photos stay there.")
        }
    }

    // MARK: Folders

    private var sidebar: some View {
        List(selection: $browser.folder) {
            if let tree = browser.tree {
                FolderRow(name: Text("All backups"), bytes: tree.bytes, count: tree.count, systemImage: "externaldrive")
                    .tag(Optional(""))
                OutlineGroup(tree.children ?? [], children: \.children) { node in
                    FolderRow(name: Text(verbatim: node.name), bytes: node.bytes, count: node.count, systemImage: "folder")
                        .tag(Optional(node.path))
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: Videos

    @ViewBuilder private var detail: some View {
        if model.destinationURL == nil {
            ContentUnavailableView("No backup location", systemImage: "externaldrive",
                                   description: Text("Choose a backup location in the main window first."))
        } else {
            switch browser.stage {
            case .idle, .scanning:
                ProgressView("Looking for videos…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView("Cannot read the backup location", systemImage: "exclamationmark.triangle",
                                       description: Text(verbatim: message))
            case .ready:
                VStack(spacing: 0) {
                    if browser.listed.isEmpty {
                        ContentUnavailableView("No videos here", systemImage: "video.slash")
                    } else {
                        List(browser.listed) { video in
                            VideoRow(video: video, browser: browser) { previewing = PreviewTarget(id: video.id) }
                        }
                        .listStyle(.inset)
                    }
                    Divider()
                    footer.padding(12)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(browser.listed.count.formatted()) videos, \(bytes(browser.listedBytes))")
                if let result = browser.trashResult {
                    HStack(spacing: 6) {
                        Text("Moved \(result.count.formatted()) videos (\(bytes(result.bytes))) to the Trash.")
                        if !result.errors.isEmpty {
                            Button("\(result.errors.count.formatted()) could not be moved") { showingTrashErrors = true }
                                .buttonStyle(.link)
                                .popover(isPresented: $showingTrashErrors) {
                                    ScrollView {
                                        Text(verbatim: result.errors.joined(separator: "\n"))
                                            .font(.caption).textSelection(.enabled).padding()
                                    }
                                    .frame(width: 460, height: 220)
                                }
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            Spacer()
            if !browser.marked.isEmpty {
                Text("Marked: \(browser.marked.count.formatted()) videos, \(bytes(browser.markedBytes))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Clear") { browser.marked = [] }
            }
            Button("Move to Trash…", role: .destructive) { confirmingTrash = true }
                .disabled(browser.marked.isEmpty || model.isBusy)
                .help(model.isBusy ? "Wait until the backup or import has finished" : "Move the marked videos to the Trash")
        }
        .controlSize(.large)
    }

    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}

private struct FolderRow: View {
    let name: Text
    let bytes: Int64
    let count: Int
    let systemImage: String

    var body: some View {
        HStack {
            Label { name.lineLimit(1).truncationMode(.middle) } icon: { Image(systemName: systemImage) }
            Spacer(minLength: 8)
            Text(verbatim: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help(Text("\(count.formatted()) videos"))
    }
}

private struct VideoRow: View {
    let video: BackupVideo
    let browser: BackupVideoBrowser
    let preview: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { browser.marked.contains(video.id) },
                set: { if $0 { browser.marked.insert(video.id) } else { browser.marked.remove(video.id) } }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            Button(action: preview) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    if let image = browser.thumbnails[video.id] {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "video").font(.title2).foregroundStyle(.secondary)
                    }
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.45))
                }
                .frame(width: 160, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Play this video")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: video.filename).font(.body.weight(.medium))
                    if video.isLivePhotoVideo {
                        Text("Live Photo").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(verbatim: browser.details(of: video))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(verbatim: ByteCountFormatter.string(fromByteCount: video.size, countStyle: .file))
                .font(.body.monospacedDigit())
        }
        .padding(.vertical, 2)
        .onAppear { browser.loadDetails(video) }
        .contextMenu {
            Button("Play") { preview() }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([video.url]) }
        }
    }
}

/// Opens the backup videos window (menu item and main-window button).
struct OpenBackupVideosButton: View {
    @Environment(BackupModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    var title: LocalizedStringKey = "Backup Videos"

    var body: some View {
        Button(title) { openWindow(id: BackupVideosView.windowID) }
            .disabled(model.destinationURL == nil)
            .help("List the videos in the backup location by size, preview them and move unwanted ones to the Trash")
    }
}

extension BackupVideosView {
    static let windowID = "backup-videos"
}
