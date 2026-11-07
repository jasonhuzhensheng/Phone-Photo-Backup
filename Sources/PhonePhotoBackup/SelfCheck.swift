import AppKit

/// Developer aid: when `PPB_SNAPSHOT_DIR` is set, the app drives scan → backup on its saved
/// folders, writes PNG snapshots of its own window into that directory, then quits.
/// Needs no Screen Recording permission because it renders its own views.
@MainActor
enum SelfCheck {
    static func runIfRequested(model: BackupModel) {
        guard let directory = ProcessInfo.processInfo.environment["PPB_SNAPSHOT_DIR"] else { return }
        let output = URL(fileURLWithPath: directory)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            snapshot(output.appendingPathComponent("1-initial.png"))
            model.scan()
            await waitUntil { model.phase != .scanning }
            snapshot(output.appendingPathComponent("2-scanned.png"))
            model.startBackup()
            await waitUntil { model.phase != .backingUp }
            snapshot(output.appendingPathComponent("3-finished.png"))
            NSApp.terminate(nil)
        }
    }

    private static func waitUntil(_ condition: () -> Bool) async {
        while !condition() { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .milliseconds(400))
    }

    private static func snapshot(_ url: URL) {
        guard let window = NSApp.windows.first(where: \.isVisible),
              let view = window.contentView?.superview ?? window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        let cg = context.cgContext
        cg.scaleBy(x: scale, y: scale)
        NSColor.windowBackgroundColor.setFill()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSRect(origin: .zero, size: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        if let layer = view.layer {
            layer.render(in: cg)
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
