# Phone Photo Backup

A native macOS app (Swift + SwiftUI) for backing up the photos and videos on a phone, read directly over USB or from a folder exported from it. Local-first: nothing is uploaded anywhere. The interface is available in English and Simplified Chinese (手机照片备份).

## Current scope

- Back up straight from a phone connected by USB: iPhone and iPad, or Android in "Transfer photos (PTP)" mode. The phone is selected automatically when it is plugged in. Originals (HEIC/HEVC) are copied, not JPEG/H.264 conversions, and the folder layout on the phone is kept.
- Or choose an exported source folder. Pick a separate backup location (button, ⌘O / ⇧⌘O, or drag a folder onto the row).
- Scan all regular files recursively and show file count and total size before copying.
- Copy files byte-for-byte, verify each copy with SHA-256, and preserve permissions, modification/access times (nanosecond precision), creation date and extended attributes (Finder tags, comments).
- Re-running the backup skips unchanged files. If a file changed, the existing copy is preserved and the new version is saved as a conflict copy (`photo.conflict-1a2b3c4d.jpg`).
- Write a local JSON manifest (`.phone-photo-backup.json`) with relative paths, hashes, sizes and version timestamps. The format is unchanged from the earlier Python version, so existing backups continue to work.
- A backup can be stopped at any time and resumed by running it again. The Mac is kept awake while copying.
- Optionally import into the Photos app after each backup, so iCloud Photos puts everything on your current iPhone. Identical files from several phones are imported once; photos already in Photos (same file name and capture time) and files imported before are skipped. Live Photos stay Live Photos. Imports are collected in the album "Imported from Old Phones".
- Automatic mode: turn on "Start automatically when a phone is connected", then plug in old phones one after another. Each is scanned, backed up and imported without any clicks; a sound plays when it is done.
- Phones with the same name ("iPhone") get separate backup folders (`iPhone_backup`, `iPhone 2_backup`).
- If the phone locks or is unplugged during a backup, the backup pauses and continues by itself once the phone is connected and unlocked again. Files already in the backup are not read from the phone again.
- Works on APFS, HFS+ and exFAT drives. Never modifies or deletes source files. Symlinks are skipped.

This version does not read the Photos library on the Mac, restore files, sync to cloud storage, or encrypt the destination. Photos kept only in iCloud ("Optimize iPhone Storage") are not on the phone and cannot be copied over USB. Android phones in "File transfer (MTP)" mode are not visible to macOS; switch them to "Transfer photos (PTP)". When a folder is the source, all regular files inside it are copied.

### Moving many old phones onto your current iPhone

1. On the Mac, open Photos and turn on iCloud Photos with the same Apple ID as your current iPhone. Make sure there is enough iCloud storage. Wait until Photos shows "Updated".
2. In this app, choose a backup location (an external drive is best) and turn on both checkboxes.
3. Plug in the old phones one at a time. Unlock each one and tap **Trust**. When the sound plays, unplug it and connect the next.
4. Photos uploads the imports to iCloud and they appear on your iPhone. Keep the backup folders.

**Import into Photos** (⇧⌘I) imports every backup in the backup location at any time, after showing how many items will be added.

### Backing up from a phone

1. Connect the phone with a USB cable and unlock it. On iPhone, tap **Trust** when asked.
2. Open the app. The phone appears as the source and its file list is read.
3. Choose a backup location, **Scan Source**, then **Start Backup**. Keep the phone unlocked until it finishes; if it locks, the backup pauses until you unlock it.

Backups from a phone go into `<phone name>_backup` in the backup location.

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
