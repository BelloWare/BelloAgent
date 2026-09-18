#!/usr/bin/env python3
"""Download the public release, check feed bytes/hash/signature, without credentials."""
import argparse
import hashlib
import pathlib
import subprocess
import xml.etree.ElementTree as ET
from release_download import DEFAULT_PREFIX, validate_prefix

parser = argparse.ArgumentParser()
parser.add_argument("release_directory", type=pathlib.Path)
parser.add_argument("scratch_directory", type=pathlib.Path)
parser.add_argument("--download-url-prefix", default=DEFAULT_PREFIX)
parser.add_argument("--archive-only", action="store_true", help="Verify the staged enclosure before publishing the appcast")
args = parser.parse_args()
validate_prefix(args.download_url_prefix)
args.scratch_directory.mkdir(parents=True, exist_ok=True)
feed_name = "bello_agent.appcast.xml"
legacy_feed_name = "pi_app.appcast.xml"
def download(url, destination):
    subprocess.run(["/usr/bin/curl", "--fail", "--location", "--silent", "--show-error",
                    "--proto", "=https", "--proto-redir", "=https", "--max-time", "600",
                    "--output", str(destination), url], check=True)


feed_path = args.release_directory / feed_name if args.archive_only else args.scratch_directory / feed_name
if not args.archive_only:
    download("https://belloware.com/assets/" + feed_name, feed_path)
feed_bytes = feed_path.read_bytes()
if feed_bytes != (args.release_directory / feed_name).read_bytes():
    raise SystemExit("Public appcast does not yet match the intended release")
if feed_bytes != (args.release_directory / legacy_feed_name).read_bytes():
    raise SystemExit("Local compatibility feed differs from the canonical appcast")
if not args.archive_only:
    compatibility_feed = args.scratch_directory / legacy_feed_name
    download("https://belloware.com/assets/" + legacy_feed_name, compatibility_feed)
    if compatibility_feed.read_bytes() != feed_bytes:
        raise SystemExit("Legacy Pi App installations are not receiving the same public update")
enclosure = ET.fromstring(feed_bytes).find("./channel/item/enclosure")
url = enclosure.attrib["url"]
name = url.rsplit("/", 1)[-1]
import re
if not re.fullmatch(r"BelloAgent-[0-9]+\.[0-9]+\.[0-9]+\.dmg", name) or url != args.download_url_prefix + name:
    raise SystemExit("Unexpected download URL")
destination = args.scratch_directory / name
download(url, destination)
actual = hashlib.sha256(destination.read_bytes()).hexdigest()
expected = hashlib.sha256((args.release_directory / name).read_bytes()).hexdigest()
if actual != expected:
    raise SystemExit("Public archive hash differs from validated local archive")
subprocess.run(["swift", str(pathlib.Path(__file__).with_name("verify-signature.swift")), str(destination),
                "slSJ7z2j8RDa266+E/7To5AOOloc2YtiMUZUVEIhwNA=",
                enclosure.attrib["{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"]], check=True)
print(f"Verified public {name}: sha256={actual}")
if not args.archive_only:
    print("Canonical Bello Agent and legacy Pi App update feeds are byte-identical.")
