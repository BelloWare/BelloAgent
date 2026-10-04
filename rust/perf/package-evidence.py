#!/usr/bin/env python3
"""Package only synthetic perf/raw evidence into deterministic, bounded Git blobs.

Run from any directory with Python 3. Local raw files are never removed or edited.
Tar entry metadata and gzip timestamps are normalized for reproducible output.
"""

from __future__ import annotations

import gzip
import hashlib
import io
import json
from pathlib import Path
import tarfile


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    raw = root / "perf" / "raw"
    output = root / "perf" / "evidence"
    files: list[Path] = []
    for path in sorted(raw.rglob("*")):
        if path.is_symlink():
            raise SystemExit(f"Refusing symlink in evidence: {path.relative_to(root)}")
        if path.is_file():
            if "\n" in str(path) or "\r" in str(path):
                raise SystemExit("Unsupported newline in evidence path")
            files.append(path)
        elif not path.is_dir() and not path.is_file():
            raise SystemExit(f"Refusing special file: {path.relative_to(root)}")
    if not files or len(files) > 2000:
        raise SystemExit("Expected 1–2000 evidence files")
    if sum(path.stat().st_size for path in files) > 64 * 1024 * 1024:
        raise SystemExit("Evidence exceeds bounded 64 MiB packaging limit")

    tar_buffer = io.BytesIO()
    hashes: list[str] = []
    byte_count = 0
    with tarfile.open(fileobj=tar_buffer, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for path in files:
            data = path.read_bytes()
            relative = path.relative_to(root).as_posix()
            digest = hashlib.sha256(data).hexdigest()
            hashes.append(f"{digest}  {relative}\n")
            byte_count += len(data)
            info = tarfile.TarInfo(relative)
            info.size = len(data)
            info.mode = 0o644
            info.uid = info.gid = info.mtime = 0
            info.uname = info.gname = ""
            archive.addfile(info, io.BytesIO(data))

    archive_buffer = io.BytesIO()
    with gzip.GzipFile(fileobj=archive_buffer, mode="wb", filename="", mtime=0, compresslevel=9) as compressed:
        compressed.write(tar_buffer.getvalue())
    data = archive_buffer.getvalue()
    output.mkdir(parents=True, exist_ok=True)
    part_size = 128 * 1024
    parts = [data[offset:offset + part_size] for offset in range(0, len(data), part_size)]
    part_hashes = []
    for index, part in enumerate(parts):
        name = f"raw-evidence.tar.gz.part-{index:03d}"
        (output / name).write_bytes(part)
        part_hashes.append(f"{hashlib.sha256(part).hexdigest()}  perf/evidence/{name}\n")
    expected_names = {f"raw-evidence.tar.gz.part-{index:03d}" for index in range(len(parts))}
    stale = [path.name for path in output.glob("raw-evidence.tar.gz.part-*") if path.name not in expected_names]
    if stale:
        raise SystemExit(f"Stale generated chunks must be reviewed before publication: {stale}")
    (output / "RAW-FILES.sha256").write_text("".join(hashes))
    (output / "PARTS.sha256").write_text("".join(part_hashes))
    digest = hashlib.sha256(data).hexdigest()
    (output / "ARCHIVE.sha256").write_text(f"{digest}  perf/evidence/raw-evidence.tar.gz\n")
    metadata = {
        "format": 1,
        "raw_files": len(files),
        "raw_bytes": byte_count,
        "archive_bytes": len(data),
        "archive_sha256": digest,
        "part_bytes_max": part_size,
        "parts": len(parts),
        "directories": sorted({path.relative_to(raw).parts[0] for path in files}),
        "scope": "Synthetic local benchmark fixtures only; not UI or Swift-relative measurements",
    }
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps(metadata, indent=2))


if __name__ == "__main__":
    main()
