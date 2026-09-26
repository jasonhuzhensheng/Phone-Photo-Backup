# Phone Photo Backup

A local-first desktop utility for backing up a folder exported from a phone. It uses Python and Tkinter; no third-party packages are required.

## Current scope

- Select an exported source folder and a separate local backup location.
- Scan all regular files recursively and show file count and total bytes before copying.
- Copy files byte-for-byte, verify each copy with SHA-256, and preserve filesystem timestamps and basic metadata.
- Re-running the backup skips unchanged files. If a file changed, the existing copy is preserved and the new version is saved as a conflict copy.
- Write a local JSON manifest with relative paths, hashes, sizes, and version timestamps.
- Never modify or delete source files. Symlinks are skipped.

This version does not connect directly to iPhone or Android devices, restore files, sync to cloud storage, or encrypt the destination. Export the phone files first, then select that folder. The chosen source folder should contain only files you intend to back up; all regular files inside it are copied.

## Run

Requires Python 3.8 or later with Tkinter. On the tested Mac, Python 3.11 and Tkinter are available. From the project root:

```sh
python3 src/desktop_app.py
```

Choose **Source folder**, choose a separate **Backup location**, click **Scan source**, review the count and size, then click **Start backup**. The app creates `<source-folder-name>_backup` inside the destination. Re-run it later to copy new or changed files.

## Test

```sh
python3 -m unittest discover -s tests -v
```

Tests use temporary simulated file bytes only.

## Privacy

The backup runs locally and does not send photos anywhere. Do not commit photos, videos, backup outputs, credentials, or local manifests to this source repository. Keep a second copy of important backups on a separate drive or storage system.
