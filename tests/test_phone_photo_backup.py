import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from phone_photo_backup import BackupError, backup, build_plan  # noqa: E402


class BackupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / "Phone Export"
        self.source.mkdir()
        (self.source / "DCIM").mkdir()
        self.photo = self.source / "DCIM" / "photo.jpg"
        self.photo.write_bytes(b"simulated photo bytes\x00\x01")
        self.destination = self.root / "External Backup"
        self.destination.mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def test_copy_is_verified_and_source_is_preserved(self):
        original = self.photo.read_bytes()
        report = backup(build_plan(self.source, self.destination))
        copied = report.backup_dir / "DCIM" / "photo.jpg"
        self.assertEqual(report.copied, 1)
        self.assertEqual(copied.read_bytes(), original)
        self.assertEqual(self.photo.read_bytes(), original)
        self.assertTrue((report.backup_dir / ".phone-photo-backup.json").is_file())

    def test_rerun_skips_unchanged_files(self):
        first = backup(build_plan(self.source, self.destination))
        second = backup(build_plan(self.source, self.destination))
        self.assertEqual(first.copied, 1)
        self.assertEqual(second.copied, 0)
        self.assertEqual(second.unchanged, 1)

    def test_changed_file_is_saved_as_a_conflict_copy(self):
        first = backup(build_plan(self.source, self.destination))
        self.photo.write_bytes(b"new simulated photo bytes")
        second = backup(build_plan(self.source, self.destination))
        original_copy = first.backup_dir / "DCIM" / "photo.jpg"
        conflict = first.backup_dir / "DCIM" / "photo.conflict-"  # prefix checked below
        conflicts = list(conflict.parent.glob(conflict.name + "*.jpg"))
        self.assertEqual(original_copy.read_bytes(), b"simulated photo bytes\x00\x01")
        self.assertEqual(len(conflicts), 1)
        self.assertEqual(conflicts[0].read_bytes(), b"new simulated photo bytes")
        manifest = json.loads((first.backup_dir / ".phone-photo-backup.json").read_text())
        self.assertEqual(len(manifest["files"]["DCIM/photo.jpg"]), 2)
        self.assertEqual(second.copied, 1)

    def test_unreadable_manifest_stops_before_modifying_backed_files(self):
        report = backup(build_plan(self.source, self.destination))
        backed_up = report.backup_dir / "DCIM" / "photo.jpg"
        original_backup = backed_up.read_bytes()
        (report.backup_dir / ".phone-photo-backup.json").write_text("not json")
        self.photo.write_bytes(b"changed source")
        with self.assertRaises(BackupError):
            backup(build_plan(self.source, self.destination))
        self.assertEqual(backed_up.read_bytes(), original_backup)

    def test_overlapping_source_and_destination_is_rejected(self):
        with self.assertRaises(BackupError):
            build_plan(self.source, self.source / "Backups")

    def test_symlink_files_are_not_followed(self):
        link = self.source / "linked.jpg"
        try:
            link.symlink_to(self.photo)
        except OSError:
            self.skipTest("symlinks unavailable")
        plan = build_plan(self.source, self.destination)
        self.assertNotIn(link, plan.files)


if __name__ == "__main__":
    unittest.main()
