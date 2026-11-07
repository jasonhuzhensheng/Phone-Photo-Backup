# Phone Photo Backup

A native macOS app (Swift + SwiftUI) for backing up a folder exported from a phone. Local-first: nothing is uploaded anywhere. The interface is available in English and Simplified Chinese (手机照片备份).

## Current scope

- Choose an exported source folder and a separate backup location (button, ⌘O / ⇧⌘O, or drag a folder onto the row).
- Scan all regular files recursively and show file count and total size before copying.
- Copy files byte-for-byte, verify each copy with SHA-256, and preserve permissions, modification/access times (nanosecond precision), creation date and extended attributes (Finder tags, comments).
- Re-running the backup skips unchanged files. If a file changed, the existing copy is preserved and the new version is saved as a conflict copy (`photo.conflict-1a2b3c4d.jpg`).
- Write a local JSON manifest (`.phone-photo-backup.json`) with relative paths, hashes, sizes and version timestamps. The format is unchanged from the earlier Python version, so existing backups continue to work.
- A backup can be stopped at any time and resumed by running it again. The Mac is kept awake while copying.
- Works on APFS, HFS+ and exFAT drives. Never modifies or deletes source files. Symlinks are skipped.

This version does not connect directly to iPhone or Android devices, restore files, sync to cloud storage, or encrypt the destination. Export the phone files first (for example with Image Capture or Finder), then select that folder. All regular files inside the chosen folder are copied.

## Requirements

macOS 14 Sonoma or later. Building needs only the Xcode Command Line Tools (`xcode-select --install`); full Xcode is optional.

## Build and run

From the project root:

```sh
scripts/build-app.sh            # → build/Phone Photo Backup.app
open "build/Phone Photo Backup.app"
scripts/build-app.sh --install  # also copies the app to /Applications
```

The app is ad-hoc signed. If you copy it to another Mac, Gatekeeper may block it the first time: right-click the app and choose **Open**.

For development, `swift run PhonePhotoBackup` launches the app without a bundle (English UI, no icon).

## Test

```sh
swift test
```

Tests use temporary simulated file bytes only.

## Privacy

The backup runs locally and does not send photos anywhere. Do not commit photos, videos, backup outputs, credentials, or local manifests to this source repository. Keep a second copy of important backups on a separate drive or storage system.
