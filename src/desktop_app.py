"""Small macOS-friendly Tkinter interface for local phone photo backups."""
from __future__ import annotations

import queue
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk
from pathlib import Path

from phone_photo_backup import BackupError, BackupPlan, backup, build_plan


class BackupApp:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.root.title("Phone Photo Backup")
        self.root.minsize(700, 330)
        self.source = tk.StringVar()
        self.destination = tk.StringVar()
        self.status = tk.StringVar(value="Choose an exported phone-photo folder and a separate backup location.")
        self.events: queue.Queue = queue.Queue()
        self.plan: BackupPlan | None = None
        self.busy = False
        self._build()
        self.root.after(100, self._poll_events)

    def _build(self) -> None:
        frame = ttk.Frame(self.root, padding=18)
        frame.pack(fill="both", expand=True)
        ttk.Label(frame, text="Phone Photo Backup", font=("TkDefaultFont", 18, "bold")).pack(anchor="w")
        ttk.Label(frame, text="Copies all files without changing or deleting the originals. Re-running skips unchanged files.", wraplength=650).pack(anchor="w", pady=(6, 16))

        self._path_row(frame, "Source folder", self.source, self._choose_source)
        self._path_row(frame, "Backup location", self.destination, self._choose_destination)

        actions = ttk.Frame(frame)
        actions.pack(fill="x", pady=(12, 6))
        self.scan_button = ttk.Button(actions, text="Scan source", command=self._scan)
        self.scan_button.pack(side="left")
        self.start_button = ttk.Button(actions, text="Start backup", command=self._start, state="disabled")
        self.start_button.pack(side="left", padx=(8, 0))
        self.progress = ttk.Progressbar(frame, mode="determinate", maximum=1)
        self.progress.pack(fill="x", pady=(8, 6))
        ttk.Label(frame, textvariable=self.status, wraplength=650).pack(anchor="w")
        ttk.Label(frame, text="The app stores no cloud copy. Source and destination must be separate folders.", wraplength=650).pack(anchor="w", pady=(14, 0))

    def _path_row(self, parent: ttk.Frame, label: str, variable: tk.StringVar, command) -> None:
        row = ttk.Frame(parent)
        row.pack(fill="x", pady=5)
        ttk.Label(row, text=label, width=16).pack(side="left", anchor="w")
        ttk.Entry(row, textvariable=variable).pack(side="left", fill="x", expand=True, padx=8)
        ttk.Button(row, text="Browse…", command=command).pack(side="right")

    def _choose_source(self) -> None:
        selected = filedialog.askdirectory(title="Choose exported phone photos")
        if selected:
            self.source.set(selected)
            self._invalidate_plan()

    def _choose_destination(self) -> None:
        selected = filedialog.askdirectory(title="Choose backup location")
        if selected:
            self.destination.set(selected)
            self._invalidate_plan()

    def _invalidate_plan(self) -> None:
        self.plan = None
        self.start_button.configure(state="disabled")
        self.status.set("Paths changed. Scan the source folder again.")

    def _set_busy(self, busy: bool) -> None:
        self.busy = busy
        state = "disabled" if busy else "normal"
        self.scan_button.configure(state=state)
        self.start_button.configure(state="disabled" if busy or self.plan is None else "normal")

    def _scan(self) -> None:
        if self.busy:
            return
        source, destination = self.source.get().strip(), self.destination.get().strip()
        if not source or not destination:
            messagebox.showerror("Missing folder", "Choose both a source folder and a backup location.")
            return
        self.plan = None
        self._set_busy(True)
        self.status.set("Scanning source files…")
        self.progress.configure(value=0, maximum=1)

        def worker() -> None:
            try:
                plan = build_plan(source, destination)
                self.events.put(("scan_done", plan))
            except Exception as error:
                self.events.put(("error", str(error)))
        threading.Thread(target=worker, daemon=True).start()

    def _start(self) -> None:
        plan = self.plan
        if plan is None or self.busy:
            return
        ok = messagebox.askyesno(
            "Start backup?",
            f"Files: {len(plan.files)}\nSize: {plan.total_bytes:,} bytes\n\nBackup folder:\n{plan.backup_dir}\n\nOriginal files will not be changed or deleted.",
        )
        if not ok:
            return
        self._set_busy(True)
        self.progress.configure(value=0, maximum=max(1, len(plan.files)))
        self.status.set("Backing up…")

        def worker() -> None:
            try:
                report = backup(plan, lambda index, total, rel, state: self.events.put(("progress", index, total, rel, state)))
                self.events.put(("done", report))
            except Exception as error:
                self.events.put(("error", str(error)))
        threading.Thread(target=worker, daemon=True).start()

    def _poll_events(self) -> None:
        try:
            while True:
                event = self.events.get_nowait()
                kind = event[0]
                if kind == "scan_done":
                    self.plan = event[1]
                    plan = self.plan
                    self.progress.configure(value=0, maximum=max(1, len(plan.files)))
                    self.status.set(f"Found {len(plan.files)} files ({plan.total_bytes:,} bytes). Backup folder: {plan.backup_dir}")
                    self._set_busy(False)
                elif kind == "progress":
                    _, index, total, relative, state = event
                    self.progress.configure(value=index, maximum=max(1, total))
                    self.status.set(f"{index}/{total}: {state} — {relative}")
                elif kind == "done":
                    report = event[1]
                    self._set_busy(False)
                    self.status.set(f"Complete: {report.copied} copied, {report.unchanged} unchanged, {len(report.errors)} errors.")
                    details = f"Copied: {report.copied}\nUnchanged: {report.unchanged}\nErrors: {len(report.errors)}\nBytes copied: {report.bytes_copied:,}\n\n{report.backup_dir}"
                    if report.errors:
                        details += "\n\n" + "\n".join(report.errors[:8])
                    messagebox.showinfo("Backup complete", details)
                elif kind == "error":
                    self._set_busy(False)
                    self.status.set("Could not complete the operation.")
                    messagebox.showerror("Backup error", event[1])
        except queue.Empty:
            pass
        self.root.after(100, self._poll_events)


def main() -> None:
    root = tk.Tk()
    BackupApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
