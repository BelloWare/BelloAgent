#!/usr/bin/env python3
"""Fail closed before publishing a feed/archive pair. Uses only public keys."""
import argparse
import pathlib
import plistlib
import subprocess
import xml.etree.ElementTree as ET
from release_download import DEFAULT_PREFIX, validate_prefix
from release_signing import validate_release_app

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
FEED = "https://belloware.com/assets/bello_agent.appcast.xml"
PUBLIC_KEY = "slSJ7z2j8RDa266+E/7To5AOOloc2YtiMUZUVEIhwNA="


def validate_metadata(feed, archive, info, previous_build=None, download_prefix=DEFAULT_PREFIX):
    validate_prefix(download_prefix)
    root = ET.parse(feed).getroot()
    items = root.findall("./channel/item")
    if len(items) != 1:
        raise ValueError("A release staging feed must contain exactly one item")
    item = items[0]
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    if info["CFBundleIdentifier"] != "com.belloware.PiApp":
        raise ValueError("Unexpected bundle identity")
    if any(info.get(key) != "Bello Agent" for key in ("CFBundleName", "CFBundleDisplayName", "CFBundleExecutable")):
        raise ValueError("Packaged application name differs from Bello Agent")
    if info["SUFeedURL"] != FEED or info["SUPublicEDKey"] != PUBLIC_KEY:
        raise ValueError("Packaged feed or signing key differs from release contract")
    if int(build) < 1 or (previous_build is not None and int(build) <= int(previous_build)):
        raise ValueError("Build number must increase; feeds must not downgrade")
    if item.findtext(SPARKLE + "version") != build:
        raise ValueError("Feed build differs from application build")
    if item.findtext(SPARKLE + "shortVersionString") != version:
        raise ValueError("Feed version differs from application version")
    enclosure = item.find("enclosure")
    expected_name = f"BelloAgent-{version}.dmg"
    if archive.name != expected_name or enclosure is None:
        raise ValueError("Incorrect archive filename or missing enclosure")
    if enclosure.get("url") != download_prefix + expected_name:
        raise ValueError("Unexpected download URL")
    if int(enclosure.get("length", "-1")) != archive.stat().st_size:
        raise ValueError("Archive size differs from feed")
    signature = enclosure.get(SPARKLE + "edSignature")
    if not signature:
        raise ValueError("Missing Ed25519 signature")
    return signature


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("feed", type=pathlib.Path)
    parser.add_argument("archive", type=pathlib.Path)
    parser.add_argument("app", type=pathlib.Path)
    parser.add_argument("--previous-build")
    parser.add_argument("--download-url-prefix", default=DEFAULT_PREFIX)
    args = parser.parse_args()
    with (args.app / "Contents/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    signature = validate_metadata(args.feed, args.archive, info, args.previous_build, args.download_url_prefix)
    verifier = pathlib.Path(__file__).with_name("verify-signature.swift")
    subprocess.run(["swift", str(verifier), str(args.archive), PUBLIC_KEY, signature], check=True)
    validate_release_app(args.app)
    subprocess.run(["xcrun", "stapler", "validate", str(args.archive)], check=True)
    subprocess.run(["spctl", "-a", "-t", "open", "--context", "context:primary-signature", str(args.archive)], check=True)
    print(f"Validated Bello Agent {info['CFBundleShortVersionString']} ({info['CFBundleVersion']})")


if __name__ == "__main__":
    main()
