# Phone Photo Backup

A native macOS app (Swift + SwiftUI) for backing up the photos and videos on a phone, read directly over USB or from a folder exported from it. Local-first: nothing is uploaded anywhere. The interface is available in English and Simplified Chinese (手机照片备份). It follows the system language; to choose one, use **Phone Photo Backup › Language** (Follow System / English / 简体中文) and restart the app when asked.

## Current scope

- Back up straight from a phone connected by USB: iPhone and iPad, or Android in "Transfer photos (PTP)" mode. The phone is selected automatically when it is plugged in. Originals (HEIC/HEVC) are copied, not JPEG/H.264 conversions, and the folder layout on the phone is kept.
- Or choose an exported source folder. Pick a separate backup location (button, ⌘O / ⇧⌘O, or drag a folder onto the row).
- Scan all regular files recursively and show file count and total size before copying.
- Copy files byte-for-byte, verify each copy with SHA-256, and preserve permissions, modification/access times (nanosecond precision), creation date and extended attributes (Finder tags, comments).
- Re-running the backup skips unchanged files. If a file changed, the existing copy is preserved and the new version is saved as a conflict copy (`photo.conflict-1a2b3c4d.jpg`).
- Write a local JSON manifest (`.phone-photo-backup.json`) with relative paths, hashes, sizes and version timestamps. The format is unchanged from the earlier Python version, so existing backups continue to work.
- A backup can be stopped at any time and resumed by running it again. The Mac is kept awake while copying.
- Optionally import into the Photos app after each backup, so iCloud Photos puts everything on your current iPhone. Identical files from several phones are imported once; photos already in Photos (same file name and capture time) and files imported before are skipped. Live Photos stay Live Photos. Imports are collected in the album "Imported from Old Phones".
- Review before backing up a phone: the app lists the largest videos (with thumbnails, length and date) and exact duplicates (same bytes; only files of identical size are read from the phone to compare). Click a thumbnail to play the video or see the photo full size: it plays from the backup copy if there is one, otherwise straight from the phone without copying the whole file first, and Keep / Delete buttons step through the list. Pick what to delete (Select All / Select None per section). Choose **Delete Selected, Then Back Up** to move the selected items to Recently Deleted first and back up only the rest, or **Back Up, Then Delete Selected** to keep a backup copy first; with the latter, after the backup, the selected items are moved to **Recently Deleted** in Photos, recoverable for 30 days, and iCloud Photos removes them from the phone. Only items with a verified backup copy are deleted, unless you choose not to back them up. Items are matched to Photos by file name and capture time (within 2 seconds, exactly one match); anything else is left alone and listed. This needs the phone and the Mac on the same Apple ID with iCloud Photos on.
- Backup Videos (button in the main window, or ⇧⌘V): every video in the backup location, largest first, with a folder tree that shows how much space each folder's videos take. Click a thumbnail to play it; mark videos and move them to the Trash (recoverable until the Trash is emptied). Live Photo videos are hidden unless you turn them on. A video that is still on a phone is copied again by that phone's next backup.
- Import a phone straight into Photos without a backup: **Import into Photos ▾ → Import This Phone Directly (No Backup)**. Items already in Photos (same name and capture time) are skipped without being read from the phone; the rest are read one at a time into a temporary folder, added, and the temporary copy is removed. The import record remembers which phone files were handled, so running it again only looks at new photos. With the review option turned on, the largest videos and duplicates are listed first (with playback): **Delete Selected, Then Import** moves the selected items that are already in Photos to Recently Deleted and leaves all selected items out of the import (and out of later imports of that phone).
- Version and updates: the version is shown next to the app name. The app checks GitHub Releases at most once a day (turn off with **Phone Photo Backup → Check for Updates Automatically**, or check now with **Check for Updates…**). When a newer version is out it shows the release notes; **Install and Restart** downloads it, checks its SHA-256, bundle identifier, version and code signature, replaces the app and restarts. Nothing is installed without that click, and not while a backup or import is running.
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

### Publishing an update

Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`, commit and push, then:

```sh
scripts/release.sh [notes.md]
```

It builds the app, zips it as `Phone-Photo-Backup-<version>.zip` and creates the GitHub release `v<version>` with the zip and its SHA-256. Installed apps pick it up on their next check. To test the updater without publishing, run the app binary with `PPB_UPDATE_FEED=file:///path/latest.json` (a file shaped like GitHub's `releases/latest` response); adding `PPB_UPDATE_AUTOINSTALL=1` installs the offer right away.

For development, `swift run PhonePhotoBackup` launches the app without a bundle (English UI, no icon).

## Test

```sh
swift test
```

Tests use temporary simulated file bytes only.

## Privacy

The backup runs locally and does not send photos anywhere. The only network request the app makes is the update check to `api.github.com` (and the download when you install an update); it sends no personal data. Do not commit photos, videos, backup outputs, credentials, or local manifests to this source repository. Keep a second copy of important backups on a separate drive or storage system.
