"""Safe, incremental, byte-for-byte backups of an exported phone-media folder."""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import tempfile
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

CHUNK_SIZE = 1024 * 1024
MANIFEST_NAME = ".phone-photo-backup.json"
SCHEMA_VERSION = 1
Progress = Callable[[int, int, str, str], None]


class BackupError(Exception):
    """A validation or backup-manifest error safe to show in the UI."""


@dataclass(frozen=True)
class BackupPlan:
    source_dir: Path
    backup_dir: Path
    files: tuple[Path, ...]
    total_bytes: int


@dataclass
class BackupReport:
    backup_dir: Path
    copied: int = 0
    unchanged: int = 0
    bytes_copied: int = 0
    errors: list[str] = field(default_factory=list)


def _walk_error(error: OSError) -> None:
    raise error


def _safe_folder_name(name: str) -> str:
    cleaned = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", name).strip(" .")
    return cleaned or "Phone Import"


def build_plan(source: str | Path, destination: str | Path) -> BackupPlan:
    """Validate paths and enumerate regular files without following symlinks."""
    source_dir = Path(source).expanduser().resolve(strict=True)
    if not source_dir.is_dir():
        raise BackupError("Choose a source folder containing the exported phone files.")

    destination_dir = Path(destination).expanduser().resolve(strict=False)
    backup_dir = destination_dir / f"{_safe_folder_name(source_dir.name)}_backup"
    if backup_dir == source_dir or backup_dir in source_dir.parents or source_dir in backup_dir.parents:
        raise BackupError("Choose a backup destination that does not overlap the source folder.")

    found: list[Path] = []

    def onerror(error: OSError) -> None:
        raise BackupError(f"Cannot read source folder: {error}") from error

    try:
        for directory, subdirs, filenames in os.walk(source_dir, topdown=True, followlinks=False, onerror=onerror):
            current = Path(directory)
            subdirs[:] = sorted(name for name in subdirs if not (current / name).is_symlink())
            for name in sorted(filenames):
                path = current / name
                if not path.is_symlink() and path.is_file():
                    found.append(path)
    except BackupError:
        raise
    except OSError as error:
        raise BackupError(f"Cannot scan source folder: {error}") from error

    files = tuple(sorted(found, key=lambda item: item.relative_to(source_dir).as_posix().casefold()))
    try:
        total_bytes = sum(path.stat().st_size for path in files)
    except OSError as error:
        raise BackupError(f"Cannot read source file details: {error}") from error
    return BackupPlan(source_dir, backup_dir, files, total_bytes)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(CHUNK_SIZE), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _same_source_snapshot(before: os.stat_result, after: os.stat_result) -> bool:
    return before.st_size == after.st_size and before.st_mtime_ns == after.st_mtime_ns


def _copy_verified(source: Path, target: Path, expected_hash: str, expected_stat: os.stat_result) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(f".{target.name}.{uuid.uuid4().hex}.part")
    digest = hashlib.sha256()
    try:
        with source.open("rb") as reader, temporary.open("xb") as writer:
            for chunk in iter(lambda: reader.read(CHUNK_SIZE), b""):
                writer.write(chunk)
                digest.update(chunk)
            writer.flush()
            os.fsync(writer.fileno())
        source_after = source.stat()
        if not _same_source_snapshot(expected_stat, source_after):
            raise BackupError("Source file changed during backup; run the backup again.")
        if digest.hexdigest() != expected_hash:
            raise BackupError("Copied file did not pass SHA-256 verification.")
        shutil.copystat(source, temporary, follow_symlinks=False)
        # Hard-link creation is atomic and fails if another process created the target.
        os.link(temporary, target)
        temporary.unlink()
    except Exception:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def _load_manifest(path: Path, source_name: str) -> dict:
    if not path.exists():
        return {"schema_version": SCHEMA_VERSION, "source_name": source_name, "updated_at": None, "files": {}}
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BackupError("The existing backup manifest is unreadable; no files were changed.") from error
    if (not isinstance(manifest, dict)
            or manifest.get("schema_version") != SCHEMA_VERSION
            or manifest.get("source_name") != source_name
            or not isinstance(manifest.get("files"), dict)):
        raise BackupError("The existing manifest does not match this backup; no files were changed.")
    return manifest


def _write_manifest(path: Path, manifest: dict) -> None:
    descriptor, temporary_name = tempfile.mkstemp(prefix=".photo-backup-manifest-", suffix=".tmp", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(manifest, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise


def _conflict_path(target: Path, digest: str) -> Path:
    candidate = target.with_name(f"{target.stem}.conflict-{digest[:8]}{target.suffix}")
    suffix = 2
    while candidate.exists():
        try:
            if candidate.is_file() and _sha256(candidate) == digest:
                return candidate
        except OSError:
            pass
        candidate = target.with_name(f"{target.stem}.conflict-{digest[:8]}-{suffix}{target.suffix}")
        suffix += 1
    return candidate


def backup(plan: BackupPlan, progress: Progress | None = None) -> BackupReport:
    """Copy and verify every source file. Never modifies or deletes source data."""
    plan.backup_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = plan.backup_dir / MANIFEST_NAME
    manifest = _load_manifest(manifest_path, plan.source_dir.name)
    report = BackupReport(plan.backup_dir)
    total = len(plan.files)

    for index, source in enumerate(plan.files, start=1):
        relative = source.relative_to(plan.source_dir).as_posix()
        status = "error"
        try:
            source_stat = source.stat()
            digest = _sha256(source)
            if not _same_source_snapshot(source_stat, source.stat()):
                raise BackupError("Source file changed while being checked; run the backup again.")

            target = plan.backup_dir / Path(relative)
            if target.exists():
                if target.is_file() and _sha256(target) == digest:
                    report.unchanged += 1
                    status = "unchanged"
                else:
                    target = _conflict_path(target, digest)
                    if target.exists() and target.is_file() and _sha256(target) == digest:
                        report.unchanged += 1
                        status = "unchanged"
                    else:
                        _copy_verified(source, target, digest, source_stat)
                        report.copied += 1
                        report.bytes_copied += source_stat.st_size
                        status = "copied"
            else:
                _copy_verified(source, target, digest, source_stat)
                report.copied += 1
                report.bytes_copied += source_stat.st_size
                status = "copied"

            versions = manifest["files"].setdefault(relative, [])
            version = next((item for item in versions if item.get("sha256") == digest), None)
            now = datetime.now(timezone.utc).isoformat()
            if version is None:
                versions.append({"sha256": digest, "size_bytes": source_stat.st_size,
                                 "backup_path": target.relative_to(plan.backup_dir).as_posix(),
                                 "first_seen": now, "last_seen": now})
            else:
                version["last_seen"] = now
                version["backup_path"] = target.relative_to(plan.backup_dir).as_posix()
        except Exception as error:
            report.errors.append(f"{relative}: {error}")
        finally:
            if progress is not None:
                progress(index, total, relative, status)

    manifest["updated_at"] = datetime.now(timezone.utc).isoformat()
    try:
        _write_manifest(manifest_path, manifest)
    except OSError as error:
        raise BackupError(f"Files were copied, but the manifest could not be saved: {error}") from error
    return report
