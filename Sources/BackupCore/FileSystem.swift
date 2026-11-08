import Darwin
import Foundation

/// Thin POSIX helpers. Everything uses `lstat`, so symbolic links are never followed.
enum FS {
    static func posixError(_ path: String, _ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSFilePathErrorKey: path,
            NSLocalizedDescriptionKey: String(cString: strerror(code)),
        ])
    }

    static func lstatInfo(_ path: String) throws -> stat {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw posixError(path) }
        return info
    }

    /// Returns nil when nothing exists at `path` (not even a dangling symlink).
    static func lstatIfExists(_ path: String) throws -> stat? {
        var info = stat()
        if lstat(path, &info) == 0 { return info }
        if errno == ENOENT { return nil }
        throw posixError(path)
    }

    static func isRegularFile(_ info: stat) -> Bool { (info.st_mode & S_IFMT) == S_IFREG }
    static func isDirectory(_ info: stat) -> Bool { (info.st_mode & S_IFMT) == S_IFDIR }

    static func realPath(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else { throw posixError(path) }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Canonical form of a path that may not exist yet: resolve the deepest existing ancestor.
    static func canonicalPath(_ path: String) -> String {
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var missing: [String] = []
        while true {
            if let resolved = try? realPath(url.path) {
                return missing.reversed().reduce(resolved) { ($0 as NSString).appendingPathComponent($1) }
            }
            if url.path == "/" { return url.path }
            missing.append(url.lastPathComponent)
            url.deleteLastPathComponent()
        }
    }

    /// True when `child` is `parent` or lives inside it. Case-insensitive to stay safe on APFS/HFS+.
    static func contains(_ parent: String, _ child: String) -> Bool {
        let p = parent.lowercased(), c = child.lowercased()
        if c == p { return true }
        return c.hasPrefix(p.hasSuffix("/") ? p : p + "/")
    }

    /// Opens a brand-new file for writing; fails if anything already exists at `path`.
    static func createExclusive(_ path: String) throws -> FileHandle {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError(path) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Writes `data` to a temporary file next to `path`, flushes it and renames it over `path`.
    static func writeAtomically(_ data: Data, to path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        let temporary = (directory as NSString)
            .appendingPathComponent(".photo-backup-\(UUID().uuidString.lowercased()).tmp")
        do {
            let handle = try createExclusive(temporary)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temporary, path) == 0 else { throw posixError(path) }
        } catch {
            unlink(temporary)
            throw error
        }
    }

    /// Forces a file's contents to permanent storage.
    static func flush(_ path: String) throws {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw posixError(path) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw posixError(path) }
    }

    /// Moves `temporary` to `target` without ever overwriting an existing file.
    /// Tries an exclusive rename, then a hard link (APFS/HFS+), then a checked rename for
    /// file systems such as exFAT that support neither.
    static func publishExclusive(_ temporary: String, to target: String) throws {
        if renamex_np(temporary, target, UInt32(RENAME_EXCL)) == 0 { return }
        if errno == EEXIST { throw posixError(target, EEXIST) }
        if link(temporary, target) == 0 {
            unlink(temporary)
            return
        }
        if errno == EEXIST { throw posixError(target, EEXIST) }
        guard try lstatIfExists(target) == nil else { throw posixError(target, EEXIST) }
        guard rename(temporary, target) == 0 else { throw posixError(target) }
    }

    /// Copies permissions, access/modification times (nanosecond precision), creation date
    /// and extended attributes (Finder tags, comments) from `source` to `destination`.
    static func copyMetadata(from source: String, to destination: String) throws {
        let info = try lstatInfo(source)
        // Extended attributes are best effort: some volumes do not support them.
        _ = copyfile(source, destination, nil, copyfile_flags_t(COPYFILE_XATTR))
        guard chmod(destination, info.st_mode & 0o7777) == 0 else { throw posixError(destination) }
        var times = [info.st_atimespec, info.st_mtimespec]
        guard utimensat(AT_FDCWD, destination, &times, 0) == 0 else { throw posixError(destination) }
        // Creation date after the modification time so APFS does not clamp it. Best effort.
        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        var created = info.st_birthtimespec
        _ = setattrlist(destination, &attributes, &created, MemoryLayout<timespec>.size, 0)
    }
}

struct FileSnapshot: Equatable {
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int

    init(_ info: stat) {
        size = Int64(info.st_size)
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
    }

    init(path: String) throws { self.init(try FS.lstatInfo(path)) }
}
