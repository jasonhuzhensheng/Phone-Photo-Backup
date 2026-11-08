import AppKit
import AVFoundation
import AVKit
import BackupCore
import SwiftUI
import UniformTypeIdentifiers

/// Feeds AVPlayer straight from a file on the phone, reading only the byte ranges the player asks
/// for. A 10 GB video starts playing, and can be scrubbed, without being copied first.
final class PhoneStreamLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    typealias Read = @Sendable (_ offset: Int64, _ length: Int) async throws -> Data

    static let scheme = "ppb-phone"
    private static let chunk: Int64 = 4 << 20

    /// All state below is only touched on this queue (AVFoundation calls the delegate on it).
    let queue = DispatchQueue(label: "PhoneStreamLoader")
    private let size: Int64
    private let contentType: String
    private let read: Read
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var invalidated = false

    init(size: Int64, contentType: String, read: @escaping Read) {
        self.size = size
        self.contentType = contentType
        self.read = read
    }

    /// A player item whose bytes come from `read`.
    func makePlayerItem(fileExtension: String) -> AVPlayerItem {
        let url = URL(string: "\(Self.scheme)://media/\(UUID().uuidString).\(fileExtension)")!
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return AVPlayerItem(asset: asset)
    }

    /// Stops every read in progress; called when the preview closes or moves on.
    func invalidate() {
        queue.async {
            self.invalidated = true
            self.tasks.values.forEach { $0.cancel() }
            self.tasks.removeAll()
        }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard !invalidated else { return false }
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = size
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }
        let start = dataRequest.requestedOffset
        let end = dataRequest.requestsAllDataToEndOfResource
            ? size : min(size, start + Int64(dataRequest.requestedLength))
        let key = ObjectIdentifier(loadingRequest)
        let request = UncheckedBox(loadingRequest)
        let read = self.read
        tasks[key] = Task {
            var offset = start
            do {
                while offset < end {
                    try Task.checkCancellation()
                    let data = try await read(offset, Int(min(Self.chunk, end - offset)))
                    try Task.checkCancellation()
                    request.value.dataRequest?.respond(with: data)
                    offset += Int64(data.count)
                }
                request.value.finishLoading()
            } catch is CancellationError {
            } catch {
                request.value.finishLoading(with: error)
            }
            self.queue.async { self.tasks[key] = nil }
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
    }
}

private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// One item a preview can show.
struct PreviewEntry: Identifiable {
    /// The path on the phone (review list) or in the backup location (backup videos).
    let id: String
    let filename: String
    let size: Int64
    let details: String
    let isVideo: Bool
    /// A file on this Mac. When nil, the preview looks for a backup copy and else reads the phone.
    let fileURL: URL?
}

/// Where to read entries that are not files on this Mac.
struct PreviewPhone {
    let deviceID: String
    /// The phone's backup folder, to play a backup copy instead of reading the phone.
    let backupDirectory: URL?
}

/// A large preview of one item from a list, with Keep and Delete buttons that move on to the next
/// item, so videos can be watched and decided on one after another. "Delete" only marks the item;
/// the list it came from does the deleting.
struct MediaPreviewSheet: View {
    @Environment(BackupModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entries: [PreviewEntry]
    @State var index: Int
    @Binding var marked: Set<String>
    var phone: PreviewPhone?
    var markedText: LocalizedStringKey = "Will be deleted"

    private enum Media {
        case loading
        case video(AVPlayer, loader: PhoneStreamLoader?, fromBackup: Bool)
        case image(NSImage, fromBackup: Bool)
        case failed(String)
    }

    @State private var media = Media.loading

    private var item: PreviewEntry { entries[index] }
    private var isSelected: Bool { marked.contains(item.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: item.filename).font(.title3.weight(.semibold))
                Text(verbatim: ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\((index + 1).formatted()) of \(entries.count.formatted())")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: item.details)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            ZStack {
                Rectangle().fill(.black)
                switch media {
                case .loading:
                    ProgressView().controlSize(.large).tint(.white)
                case .video(let player, _, _):
                    PlayerView(player: player)
                case .image(let image, _):
                    Image(nsImage: image).resizable().scaledToFit()
                case .failed(let message):
                    Label { Text(verbatim: message) } icon: { Image(systemName: "exclamationmark.triangle") }
                        .foregroundStyle(.white)
                        .padding()
                }
            }
            .frame(minWidth: 760, idealWidth: 960, minHeight: 430, idealHeight: 540)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(sourceNote)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button { index -= 1 } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .disabled(index == 0)
                    .help("Previous (⌘←)")
                Button { index += 1 } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .disabled(index == entries.count - 1)
                    .help("Next (⌘→)")

                Label(isSelected ? markedText : "Will be kept",
                      systemImage: isSelected ? "trash" : "checkmark.circle")
                    .foregroundStyle(isSelected ? .red : .green)
                    .padding(.leading, 8)

                Spacer()
                Button("Keep") { decide(delete: false) }
                    .keyboardShortcut("k", modifiers: .command)
                    .help("Keep this item and show the next one (⌘K)")
                Button("Delete", role: .destructive) { decide(delete: true) }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .help("Mark this item for deletion and show the next one (⌘⌫)")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .task(id: item.id) { await load(item) }
        .onDisappear { stop() }
    }

    private var sourceNote: LocalizedStringKey {
        switch media {
        case .video(_, _, fromBackup: true), .image(_, fromBackup: true):
            "Showing the backup copy on this Mac."
        case .video(_, _, fromBackup: false):
            "Playing straight from the phone. Large videos may pause while loading; keep the phone unlocked."
        case .image(_, fromBackup: false):
            "Read from the phone."
        case .loading:
            "Loading from the phone…"
        case .failed:
            "The preview could not be loaded. You can still decide from the details above."
        }
    }

    private func decide(delete: Bool) {
        if delete { marked.insert(item.id) } else { marked.remove(item.id) }
        if index < entries.count - 1 { index += 1 }
    }

    private func stop() {
        if case .video(let player, let loader, _) = media {
            player.pause()
            player.replaceCurrentItem(with: nil)
            loader?.invalidate()
        }
    }

    private func load(_ item: PreviewEntry) async {
        stop()
        media = .loading
        let backupCopy = item.fileURL ?? phone?.backupDirectory.flatMap {
            PhoneReview.backupCopy(of: PhoneItem(relativePath: item.id, size: item.size, date: nil), in: $0)
        }
        let devices = model.devices
        let path = item.id
        let size = item.size
        let ext = (path as NSString).pathExtension.lowercased()
        guard backupCopy != nil || phone != nil else {
            media = .failed(String(localized: "The file is no longer there."))
            return
        }
        let deviceID = phone?.deviceID ?? ""

        if item.isVideo {
            let player: AVPlayer
            var loader: PhoneStreamLoader?
            if let backupCopy {
                player = AVPlayer(url: backupCopy)
            } else {
                let type = UTType(filenameExtension: ext)?.identifier ?? UTType.movie.identifier
                let streamer = PhoneStreamLoader(size: item.size, contentType: type) { offset, length in
                    try await devices.readData(deviceID: deviceID, path: path, size: size, offset: offset, length: length)
                }
                player = AVPlayer(playerItem: streamer.makePlayerItem(fileExtension: ext))
                loader = streamer
            }
            media = .video(player, loader: loader, fromBackup: backupCopy != nil)
            player.play()
            return
        }

        do {
            let data: Data
            if let backupCopy {
                data = try Data(contentsOf: backupCopy, options: .mappedIfSafe)
            } else {
                var buffer = Data(capacity: Int(item.size))
                while Int64(buffer.count) < item.size {
                    try Task.checkCancellation()
                    let length = Int(min(8 << 20, item.size - Int64(buffer.count)))
                    buffer.append(try await devices.readData(deviceID: deviceID, path: path, size: size,
                                                             offset: Int64(buffer.count), length: length))
                }
                data = buffer
            }
            try Task.checkCancellation()
            guard let image = NSImage(data: data) else {
                media = .failed(String(localized: "This file cannot be shown as an image."))
                return
            }
            media = .image(image, fromBackup: backupCopy != nil)
        } catch is CancellationError {
        } catch {
            media = .failed(error.localizedDescription)
        }
    }
}

extension PhoneItem {
    /// Date, video length and folder, for the review list and the preview.
    var reviewDetails: String {
        var parts: [String] = []
        if let date { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
        if let duration {
            parts.append(Duration.seconds(duration).formatted(.time(pattern: duration >= 3600 ? .hourMinuteSecond : .minuteSecond)))
        }
        parts.append((relativePath as NSString).deletingLastPathComponent)
        return parts.joined(separator: " · ")
    }
}
