#!/usr/bin/env python3
"""Synthetic integrity/safety controls. Never runs the transported executables."""
import base64
import copy
import gzip
import importlib.util
import io
import json
from pathlib import Path
import os
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("transfer", Path(__file__).with_name("source-utf8-log-transfer.py"))
t = importlib.util.module_from_spec(spec)
spec.loader.exec_module(t)
COMMIT = "a" * 40


class TransferTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle = self.root / "input"
        self.bundle.mkdir()
        for name in t.FILES:
            # Deliberately exceed one chunk after compression.
            (self.bundle / name).write_bytes(os.urandom(5000))
            (self.bundle / name).chmod(0o755 if name in {"rust-probe", "swift-oracle"} else 0o644)
        self.manifest = {"schema": 1, "commit": COMMIT,
                         "files": {name: t.sha((self.bundle / name).read_bytes()) for name in t.FILES}}
        self.receipt = self.root / "receipt.json"
        self.rows = [{"case": "synthetic", "input": "c3a9", "output": "c3a9"}]
        self.write_identity()
        self.archive, self.commit = t.pack(self.bundle, self.receipt)
        self.log = self.logs(self.archive)
        self.records = [json.loads(line[len(t.PREFIX):]) for line in self.log.splitlines()]

    def write_identity(self):
        (self.bundle / "manifest.json").write_text(json.dumps(self.manifest))
        self.receipt.write_text(json.dumps({"schema": 1, "passed": True,
            "manifest_sha256": t.sha((self.bundle / "manifest.json").read_bytes()),
            "files": self.manifest["files"], "actual": self.rows, "expected": self.rows}))

    def logs(self, archive):
        result = io.StringIO()
        t.emit_records(archive, COMMIT, result)
        return result.getvalue()

    def serial(self, records):
        return "".join(t.PREFIX + json.dumps(row) + "\n" for row in records)

    def reject(self, log, **kwargs):
        target = self.root / "out"
        with self.assertRaises((ValueError, OSError, EOFError, tarfile.TarError)):
            t.decode(io.StringIO(log), target, **kwargs)
        self.assertFalse(target.exists())

    def test_plain_and_timestamp_roundtrip_byte_identical(self):
        for number, prefix in enumerate(("", "2026-10-08T18:00:00.1234567Z ")):
            log = "noise before\n" + "".join(prefix + line + "\n" for line in self.log.splitlines()) + "noise after\n"
            target = self.root / f"out{number}"
            identity = t.decode(io.StringIO(log), target, t.sha(self.archive), COMMIT)
            self.assertEqual(identity["archive_sha256"], t.sha(self.archive))
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE((target / t.BUNDLE).stat().st_mode), 0o700)
            for source in self.bundle.iterdir():
                recovered = target / t.BUNDLE / source.name
                self.assertEqual(source.read_bytes(), recovered.read_bytes())
                self.assertEqual(stat.S_IMODE(source.stat().st_mode), stat.S_IMODE(recovered.stat().st_mode))
            self.assertEqual(self.receipt.read_bytes(), (target / t.RECEIPT).read_bytes())

    def test_github_segment_bom_at_chunk_boundaries_roundtrip(self):
        # Real CI logs had U+FEFF before UTC timestamps on chunks 158 and 327.
        (self.bundle / "rust-probe").write_bytes(os.urandom(4 * 1024 * 1024))
        self.manifest["files"]["rust-probe"] = t.sha((self.bundle / "rust-probe").read_bytes())
        self.write_identity()
        archive, _ = t.pack(self.bundle, self.receipt)
        lines = self.logs(archive).splitlines()
        self.assertGreater(len(lines), 330)
        timestamp = "2026-10-08T18:50:00.1234567Z "
        log = "\n".join(("\ufeff" if index in {159, 328} else "") + timestamp + line
                        for index, line in enumerate(lines)) + "\n"
        target = self.root / "segment-out"
        t.decode(io.StringIO(log), target, t.sha(archive), COMMIT)
        for source in self.bundle.iterdir():
            recovered = target / t.BUNDLE / source.name
            self.assertEqual(source.read_bytes(), recovered.read_bytes())
            self.assertEqual(stat.S_IMODE(source.stat().st_mode), stat.S_IMODE(recovered.stat().st_mode))
        self.assertEqual(self.receipt.read_bytes(), (target / t.RECEIPT).read_bytes())

    def test_segment_bom_incomplete_through_chunk495_of510_still_rejected(self):
        stream = io.StringIO()
        t.emit_records(b"x" * 4696612, COMMIT, stream)
        lines = stream.getvalue().splitlines()
        self.assertEqual(json.loads(lines[0][len(t.PREFIX):])["chunk_count"], 510)
        # Begin plus chunks 0–495 (496 chunks), no end: match the live snapshot.
        incomplete = "\n".join(("\ufeff" if index in {159, 328} else "") +
            "2026-10-08T18:50:00.1234567Z " + line
            for index, line in enumerate(lines[:497])) + "\n"
        with self.assertRaisesRegex(ValueError, "missing complete bundle"):
            t.decode_records(io.StringIO(incomplete))

    def test_bom_only_allowed_once_before_valid_timestamp(self):
        for prefix in ("\ufeff", "\ufeff\ufeff2026-10-08T18:50:00Z ",
                       "\ufeff2026-10-08T18:50:00+00:00 ", "\ufeffnot-a-timestamp ",
                       "2026-10-08T18:50:00Z \ufeff", " \ufeff2026-10-08T18:50:00Z "):
            with self.subTest(prefix=repr(prefix)):
                self.reject(prefix + self.log)
        self.reject(self.log.replace(t.PREFIX + "{", t.PREFIX + "\ufeff{", 1))
        encoded = self.records[1]["data"]
        self.reject(self.log.replace(encoded, encoded[:50] + "\ufeff" + encoded[50:], 1))
        self.reject(self.log.replace('"schema":1', '"schema":\ufeff1', 1))

    def test_missing_duplicate_reordered_and_extra_records(self):
        variants = [self.records[1:], self.records[:-1], self.records[:1] + self.records[2:],
                    [self.records[0]] + self.records, self.records[:2] + self.records[1:],
                    self.records + self.records, self.records + [self.records[1]],
                    self.records[:1] + self.records[2:3] + self.records[1:2] + self.records[3:],
                    [self.records[-1]], []]
        for records in variants:
            with self.subTest(records=len(records)):
                self.reject(self.serial(records))

    def test_header_and_footer_controls(self):
        changes = {"schema": [2, True], "source_commit": ["bad", "b" * 40],
                   "archive_bytes": [0, -1, True, t.MAX_ARCHIVE + 1],
                   "archive_sha256": ["bad", "0" * 64], "chunk_count": [0, True, 999999]}
        for field, values in changes.items():
            for value in values:
                with self.subTest(field=field, value=value):
                    rows = copy.deepcopy(self.records)
                    rows[0][field] = rows[-1][field] = value
                    self.reject(self.serial(rows))
        rows = copy.deepcopy(self.records)
        rows[-1]["archive_sha256"] = "0" * 64
        self.reject(self.serial(rows))
        for position in (0, 1, -1):
            rows = copy.deepcopy(self.records)
            rows[position]["extra"] = 1
            self.reject(self.serial(rows))
        self.reject(self.log, expected_sha="0" * 64)
        self.reject(self.log, expected_sha="bad")
        self.reject(self.log, expected_commit="b" * 40)

    def test_chunk_controls(self):
        for key, value in [("index", True), ("index", -1), ("bytes", True), ("bytes", t.CHUNK_BYTES + 1),
                           ("sha256", "0" * 64), ("data", "!" * 12288), ("data", "AAAA"),
                           ("type", "other")]:
            with self.subTest(key=key):
                rows = copy.deepcopy(self.records)
                rows[1][key] = value
                self.reject(self.serial(rows))
        # Change data while keeping its length and original checksum.
        rows = copy.deepcopy(self.records)
        rows[1]["data"] = "AAAA" + rows[1]["data"][4:]
        self.reject(self.serial(rows))

    def test_duplicate_json_keys_wrapping_and_oversize(self):
        self.reject(self.log.replace('"schema":1', '"schema":1,"schema":1', 1))
        self.reject(self.log.replace('"index":0', '"index":NaN', 1))
        self.reject(self.log.replace(self.records[1]["data"][:100], self.records[1]["data"][:50] + "\n" + self.records[1]["data"][50:100], 1))
        self.reject("x" * (t.MAX_RECORD + 1) + "\n" + self.log)
        self.reject("bad prefix " + self.log)
        with mock.patch.object(t, "MAX_LOG", 10):
            self.reject(self.log)

    def test_noncanonical_base64(self):
        # 1 raw byte uses two pad characters; vary unused bits without changing byte.
        stream = io.StringIO()
        t.emit_records(b"x", COMMIT, stream)
        self.reject(stream.getvalue().replace('"eA=="', '"eB=="'))

    def test_full_archive_sha_verified(self):
        rows = copy.deepcopy(self.records)
        data = bytearray(base64.b64decode(rows[1]["data"]))
        data[0] ^= 1
        rows[1]["data"] = base64.b64encode(data).decode()
        rows[1]["sha256"] = t.sha(data)
        self.reject(self.serial(rows))

    def test_existing_output_preserved(self):
        target = self.root / "out"
        target.mkdir()
        (target / "sentinel").write_bytes(b"keep")
        with self.assertRaises(ValueError):
            t.decode(io.StringIO(self.log), target)
        self.assertEqual((target / "sentinel").read_bytes(), b"keep")
        link = self.root / "link"
        link.symlink_to(self.root / "missing")
        with self.assertRaises(ValueError):
            t.decode(io.StringIO(self.log), link)
        self.assertTrue(link.is_symlink())

    def test_creation_race_preserves_existing_output(self):
        original = t.unpack
        target = self.root / "out"
        def race(*args):
            value = original(*args)
            target.mkdir()
            (target / "sentinel").write_bytes(b"keep")
            return value
        with mock.patch.object(t, "unpack", side_effect=race), self.assertRaises(FileExistsError):
            t.decode(io.StringIO(self.log), target)
        self.assertEqual((target / "sentinel").read_bytes(), b"keep")

    def altered_archive(self, alter):
        raw = io.BytesIO()
        with tarfile.open(fileobj=raw, mode="w", format=tarfile.USTAR_FORMAT) as target:
            with tarfile.open(fileobj=io.BytesIO(self.archive), mode="r:gz") as source:
                entries = [(entry, source.extractfile(entry).read()) for entry in source]
            for entry, data in alter(entries):
                target.addfile(entry, io.BytesIO(data) if entry.isreg() else None)
        return gzip.compress(raw.getvalue(), mtime=0)

    def test_tar_symlink_hardlink_fifo_directory_traversal_and_duplicates(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE, tarfile.CHRTYPE):
            def alter(entries):
                entries[0][0].type = kind
                entries[0][0].linkname = "/tmp/victim"
                entries[0][0].size = 0
                return entries
            with self.subTest(kind=kind):
                self.reject(self.logs(self.altered_archive(alter)))
        for path in ("../victim", "/tmp/victim", "a4-modern-bundle/../rust-probe", "unexpected"):
            def alter(entries):
                entries[0][0].name = path
                return entries
            with self.subTest(path=path):
                self.reject(self.logs(self.altered_archive(alter)))
        self.reject(self.logs(self.altered_archive(lambda entries: entries + entries[:1])))
        self.reject(self.logs(self.altered_archive(lambda entries: entries[:-1])))
        def unsafe_mode(entries):
            entries[0][0].mode = 0o4755
            return entries
        self.reject(self.logs(self.altered_archive(unsafe_mode)))

    def test_expansion_and_truncated_archives(self):
        with mock.patch.object(t, "MAX_UNPACKED", 1024):
            self.reject(self.log)
        self.reject(self.logs(self.archive[:-10]))
        self.reject(self.logs(b"not gzip"))
        self.reject(self.logs(gzip.compress(gzip.decompress(self.archive) + b"hidden")))

    def test_manifest_receipt_and_artifact_validation(self):
        for name in t.FILES:
            path = self.bundle / name
            original = path.read_bytes()
            path.write_bytes(b"tampered")
            with self.subTest(name=name), self.assertRaises(ValueError):
                t.pack(self.bundle, self.receipt)
            path.write_bytes(original)
        original = json.loads(self.receipt.read_text())
        for key, value in [("schema", True), ("schema", 2), ("passed", False), ("passed", 1),
                           ("actual", []), ("expected", []), ("manifest_sha256", "0" * 64),
                           ("files", {})]:
            receipt = dict(original, **{key: value})
            self.receipt.write_text(json.dumps(receipt))
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                t.pack(self.bundle, self.receipt)
        self.receipt.write_text(json.dumps(original))
        self.manifest["schema"] = True
        self.write_identity()
        with self.assertRaises(ValueError):
            t.pack(self.bundle, self.receipt)

    def test_decode_revalidates_archived_manifest_receipt_and_files(self):
        for name in ("a4-modern-bundle/rust-probe", "a4-modern-bundle/manifest.json", t.RECEIPT):
            def alter(entries):
                updated = []
                for entry, data in entries:
                    if entry.name == name:
                        if name.endswith("manifest.json"):
                            value = json.loads(data)
                            value["commit"] = "b" * 40
                            data = json.dumps(value).encode()
                        elif name == t.RECEIPT:
                            value = json.loads(data)
                            value["passed"] = False
                            data = json.dumps(value).encode()
                        else:
                            data += b"corrupt"
                        entry.size = len(data)
                    updated.append((entry, data))
                return updated
            with self.subTest(name=name):
                self.reject(self.logs(self.altered_archive(alter)))

    def test_cli_emit_decode_and_failure(self):
        script = str(Path(__file__).with_name("source-utf8-log-transfer.py"))
        emission = subprocess.run([sys.executable, script, "emit", str(self.bundle),
            "--receipt", str(self.receipt)], capture_output=True, check=True)
        path = self.root / "job.log"
        path.write_bytes(emission.stdout)
        target = self.root / "cli-out"
        result = subprocess.run([sys.executable, script, "decode", str(path), str(target),
            "--expected-sha256", t.sha(self.archive), "--expected-source-commit", COMMIT],
            capture_output=True, check=True)
        self.assertTrue(json.loads(result.stdout)["verified"])
        result = subprocess.run([sys.executable, script, "decode", str(path), str(target)],
            capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"output already exists", result.stderr)

    def test_emit_rejects_extra_file_symlink_missing_execute_and_limits(self):
        extra = self.bundle / "extra"
        extra.write_text("x")
        with self.assertRaises(ValueError):
            t.pack(self.bundle, self.receipt)
        extra.unlink()
        path = self.bundle / "rust-probe"
        original = path.read_bytes()
        path.unlink()
        path.symlink_to(self.receipt)
        with self.assertRaises(ValueError):
            t.pack(self.bundle, self.receipt)
        path.unlink()
        path.write_bytes(original)
        with self.assertRaises(ValueError):
            t.pack(self.bundle, self.receipt)
        path.chmod(0o755)
        with mock.patch.object(t, "MAX_ARCHIVE", 1), self.assertRaises(ValueError):
            t.pack(self.bundle, self.receipt)
        with mock.patch.object(t, "MAX_UNPACKED", 1), self.assertRaises(ValueError):
            t.pack(self.bundle, self.receipt)


if __name__ == "__main__":
    unittest.main()
