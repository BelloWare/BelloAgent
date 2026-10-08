#!/usr/bin/env python3
"""Transport one verified A4 bundle through CI logs without artifact storage.

emit BUNDLE --receipt RECEIPT > log.txt
decode log.txt NEW_OUTPUT [--expected-sha256 SHA] [--expected-source-commit COMMIT]

Decode never executes binaries. Hashes provide integrity, not authenticity: obtain
an expected archive SHA/source commit through a trusted CI run when required.
"""
import argparse
import base64
import binascii
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import shutil
import stat
import sys
import tarfile

PREFIX = "BELLO_A4_BUNDLE_V1 "
MAX_ARCHIVE = 16 * 1024 * 1024
MAX_UNPACKED = 256 * 1024 * 1024
CHUNK_BYTES = 9 * 1024
MAX_RECORD = 16 * 1024
MAX_LOG = 128 * 1024 * 1024
FILES = {"rust-probe", "swift-oracle", "bridge.a", "bridge-Swift.h", "build.json", "oracle.swift"}
BUNDLE = "a4-modern-bundle"
RECEIPT = "a4-modern-receipt.json"
PATHS = {f"{BUNDLE}/{name}" for name in FILES | {"manifest.json"}} | {RECEIPT}
SHA = re.compile(r"[0-9a-f]{64}\Z")
COMMIT = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
# GitHub concatenated log segments can start with one UTF-8 BOM. Accept it
# only as part of this anchored UTC timestamp prefix, never via general stripping.
TIMESTAMP = re.compile(r"^\ufeff?\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z ")
IDENTITY = {"schema", "source_commit", "archive_bytes", "archive_sha256", "chunk_count"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key: {key}")
        result[key] = value
    return result


def read_json(data):
    def invalid(value):
        raise ValueError(f"nonfinite JSON: {value}")
    return json.loads(data, object_pairs_hook=unique_object, parse_constant=invalid)


def valid_sha(value):
    return isinstance(value, str) and SHA.fullmatch(value) is not None


def validate_payload(payload, source_commit=None):
    require(set(payload) == PATHS, "incomplete or unexpected archive files")
    manifest_data = payload[f"{BUNDLE}/manifest.json"][0]
    manifest = read_json(manifest_data)
    receipt = read_json(payload[RECEIPT][0])
    require(isinstance(manifest, dict) and type(manifest.get("schema")) is int
            and manifest["schema"] == 1, "unsupported manifest schema")
    commit = manifest.get("commit")
    require(isinstance(commit, str) and COMMIT.fullmatch(commit), "invalid source commit")
    require(source_commit is None or commit == source_commit, "source commit mismatch")
    hashes = manifest.get("files")
    require(isinstance(hashes, dict) and set(hashes) == FILES, "incomplete manifest hashes")
    for name, expected in hashes.items():
        require(valid_sha(expected) and sha(payload[f"{BUNDLE}/{name}"][0]) == expected,
                f"artifact hash mismatch: {name}")
    require(isinstance(receipt, dict) and type(receipt.get("schema")) is int
            and receipt["schema"] == 1, "unsupported receipt schema")
    require(receipt.get("passed") is True, "modern receipt did not pass")
    actual, expected = receipt.get("actual"), receipt.get("expected")
    require(isinstance(actual, list) and len(actual) > 0 and actual == expected,
            "modern receipt actual/expected mismatch or empty")
    cases = set()
    for row in actual:
        require(isinstance(row, dict) and set(row) == {"case", "input", "output"},
                "invalid receipt case")
        require(isinstance(row["case"], str) and row["case"] and row["case"] not in cases,
                "invalid or duplicate receipt case")
        cases.add(row["case"])
        for key in ("input", "output"):
            value = row[key]
            require((key == "output" and value is None) or
                    (isinstance(value, str) and re.fullmatch(r"(?:[0-9a-f]{2})*", value)),
                    "invalid receipt hex bytes")
    require(receipt.get("manifest_sha256") == sha(manifest_data)
            and receipt.get("files") == hashes, "modern receipt bundle identity mismatch")
    for name in ("rust-probe", "swift-oracle"):
        require(payload[f"{BUNDLE}/{name}"][1] & 0o111, f"missing executable mode: {name}")
    return commit


def pack(bundle, receipt):
    bundle, receipt = Path(bundle), Path(receipt)
    require(not bundle.is_symlink() and bundle.is_dir(), "bundle must be a real directory")
    require({p.name for p in bundle.iterdir()} == FILES | {"manifest.json"},
            "bundle directory must contain exactly seven files")
    payload, total = {}, 0
    for name in sorted(PATHS):
        source = receipt if name == RECEIPT else bundle / name.split("/")[1]
        info = source.lstat()
        require(stat.S_ISREG(info.st_mode), f"not a regular file: {source}")
        total += info.st_size
        require(total <= MAX_UNPACKED - 10240, "unpacked bundle exceeds limit")
        with source.open("rb") as stream:
            data = stream.read(info.st_size + 1)
        require(len(data) == info.st_size, "file changed while reading")
        payload[name] = (data, stat.S_IMODE(info.st_mode) & 0o777)
    commit = validate_payload(payload)
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for name, (data, mode) in sorted(payload.items()):
            entry = tarfile.TarInfo(name)
            entry.size, entry.mode, entry.mtime = len(data), mode, 0
            archive.addfile(entry, io.BytesIO(data))
    require(raw.tell() <= MAX_UNPACKED, "unpacked tar exceeds limit")
    compressed = gzip.compress(raw.getvalue(), mtime=0)
    require(len(compressed) <= MAX_ARCHIVE, "archive exceeds 16 MiB")
    return compressed, commit


def emit_records(archive, commit, stream):
    require(0 < len(archive) <= MAX_ARCHIVE, "invalid archive size")
    require(isinstance(commit, str) and COMMIT.fullmatch(commit), "invalid source commit")
    identity = {"schema": 1, "source_commit": commit, "archive_bytes": len(archive),
                "archive_sha256": sha(archive),
                "chunk_count": (len(archive) + CHUNK_BYTES - 1) // CHUNK_BYTES}
    def write(record):
        stream.write(PREFIX + json.dumps(record, separators=(",", ":"), sort_keys=True) + "\n")
    write({"type": "begin", **identity})
    for index, offset in enumerate(range(0, len(archive), CHUNK_BYTES)):
        data = archive[offset:offset + CHUNK_BYTES]
        write({"type": "chunk", "index": index, "bytes": len(data), "sha256": sha(data),
               "data": base64.b64encode(data).decode("ascii")})
    write({"type": "end", **identity})
    return identity


def decode_records(stream, expected_sha=None, expected_commit=None):
    require(expected_sha is None or valid_sha(expected_sha), "invalid expected SHA")
    require(expected_commit is None or COMMIT.fullmatch(expected_commit), "invalid expected commit")
    identity, pieces, finished, consumed = None, [], False, 0
    while True:
        raw = stream.readline(MAX_RECORD + 1)
        if not raw:
            break
        line_bytes = len(raw.encode("utf-8"))
        consumed += line_bytes
        require(consumed <= MAX_LOG, "log exceeds 128 MiB")
        require(line_bytes <= MAX_RECORD, "log line exceeds 16 KiB; wrapped/oversize record")
        line = TIMESTAMP.sub("", raw.rstrip("\r\n"), count=1)
        if not line.startswith(PREFIX):
            require(PREFIX.strip() not in line, "malformed record prefix")
            continue
        require(not finished, "extra bundle or record after end")
        record = read_json(line[len(PREFIX):])
        require(isinstance(record, dict), "record must be an object")
        kind = record.get("type")
        if kind == "begin":
            require(identity is None, "duplicate begin")
            require(set(record) == IDENTITY | {"type"}, "invalid begin fields")
            identity = {key: record[key] for key in IDENTITY}
            require(type(identity["schema"]) is int and identity["schema"] == 1, "unsupported schema")
            require(isinstance(identity["source_commit"], str)
                    and COMMIT.fullmatch(identity["source_commit"]), "invalid source commit")
            size, count = identity["archive_bytes"], identity["chunk_count"]
            require(type(size) is int and 0 < size <= MAX_ARCHIVE, "archive size exceeds limit")
            require(type(count) is int and count == (size + CHUNK_BYTES - 1) // CHUNK_BYTES,
                    "invalid chunk count")
            require(valid_sha(identity["archive_sha256"]), "invalid archive SHA")
            require(expected_sha is None or identity["archive_sha256"] == expected_sha,
                    "expected archive SHA mismatch")
            require(expected_commit is None or identity["source_commit"] == expected_commit,
                    "expected source commit mismatch")
        elif kind == "chunk":
            require(identity is not None, "chunk before begin")
            require(set(record) == {"type", "index", "bytes", "sha256", "data"}, "invalid chunk fields")
            index = record["index"]
            require(type(index) is int and index == len(pieces) and index < identity["chunk_count"],
                    "duplicate, reordered or excess chunk")
            size = min(CHUNK_BYTES, identity["archive_bytes"] - index * CHUNK_BYTES)
            require(type(record["bytes"]) is int and record["bytes"] == size, "invalid chunk bytes")
            require(isinstance(record["data"], str) and len(record["data"]) == 4 * ((size + 2) // 3),
                    "invalid base64 size")
            try:
                data = base64.b64decode(record["data"], validate=True)
            except (ValueError, binascii.Error):
                raise ValueError("invalid base64") from None
            require(base64.b64encode(data).decode("ascii") == record["data"], "noncanonical base64")
            require(len(data) == size and valid_sha(record["sha256"])
                    and sha(data) == record["sha256"], "chunk SHA/size mismatch")
            pieces.append(data)
        elif kind == "end":
            require(identity is not None, "end before begin")
            require(set(record) == IDENTITY | {"type"}
                    and all(type(record[key]) is type(identity[key]) and record[key] == identity[key]
                            for key in IDENTITY), "end identity mismatch")
            require(len(pieces) == identity["chunk_count"], "missing chunks")
            finished = True
        else:
            raise ValueError("unknown record type")
    require(finished, "missing complete bundle")
    data = b"".join(pieces)
    require(len(data) == identity["archive_bytes"] and sha(data) == identity["archive_sha256"],
            "full archive SHA/size mismatch")
    return data, identity


def unpack(archive, commit):
    require(0 < len(archive) <= MAX_ARCHIVE, "archive size exceeds limit")
    # Bounded decompression before tar parsing also bounds extension-header work.
    with gzip.GzipFile(fileobj=io.BytesIO(archive), mode="rb") as compressed:
        raw = compressed.read(MAX_UNPACKED + 1)
    require(len(raw) <= MAX_UNPACKED, "unpacked tar exceeds 256 MiB")
    payload, seen, total = {}, set(), 0
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as tar:
        for entry in tar:
            require(entry.name not in seen, "duplicate tar path")
            seen.add(entry.name)
            require(not entry.pax_headers, "tar extension headers are unsupported")
            if entry.isdir():
                require(entry.name == BUNDLE, "unexpected tar directory")
                continue
            require(entry.name in PATHS and entry.isreg() and entry.type in (tarfile.REGTYPE, tarfile.AREGTYPE),
                    "unsafe or unexpected tar member")
            require(entry.mode & ~0o777 == 0, "unsafe tar mode")
            total += entry.size
            require(entry.size >= 0 and total <= MAX_UNPACKED, "file sizes exceed limit")
            stream = tar.extractfile(entry)
            data = stream.read(entry.size + 1)
            require(len(data) == entry.size, "truncated tar member")
            payload[entry.name] = (data, entry.mode)
        # No hidden second tar or nonzero trailing material after the EOF marker.
        require(not any(raw[tar.offset:]), "nonzero trailing tar data")
    validate_payload(payload, commit)
    return payload


def decode(stream, output, expected_sha=None, expected_commit=None):
    output = Path(output)
    require(not output.exists() and not output.is_symlink(), "output already exists")
    archive, identity = decode_records(stream, expected_sha, expected_commit)
    payload = unpack(archive, identity["source_commit"])
    # Reserve the output atomically, only after every verification passed. Never
    # replace an existing destination, including one created during validation.
    output.mkdir(mode=0o700)
    try:
        (output / BUNDLE).mkdir(mode=0o700)
        for name, (data, mode) in payload.items():
            target = output / name
            with target.open("xb") as file:
                file.write(data)
            target.chmod(mode)
    except BaseException:
        shutil.rmtree(output)
        raise
    return identity


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest="mode", required=True)
    emit = modes.add_parser("emit")
    emit.add_argument("bundle", type=Path)
    emit.add_argument("--receipt", required=True, type=Path)
    recover = modes.add_parser("decode")
    recover.add_argument("log", type=Path)
    recover.add_argument("output", type=Path)
    recover.add_argument("--expected-sha256")
    recover.add_argument("--expected-source-commit")
    args = parser.parse_args()
    try:
        if args.mode == "emit":
            archive, commit = pack(args.bundle, args.receipt)
            emit_records(archive, commit, sys.stdout)
        else:
            with args.log.open("r", encoding="utf-8", errors="strict", newline="") as stream:
                identity = decode(stream, args.output, args.expected_sha256, args.expected_source_commit)
            print(json.dumps({"verified": True, "output": str(args.output), **identity}, sort_keys=True))
    except (ValueError, OSError, EOFError, tarfile.TarError) as error:
        parser.exit(1, f"A4 log transport: {error}\n")


if __name__ == "__main__":
    main()
