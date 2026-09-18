#!/usr/bin/env python3
"""Profile-free Developer ID signing, matching BelloClipboard's release model.

The app uses the ordinary login Keychain and needs no Keychain access-group
entitlement or provisioning profile. Every distribution signature still needs
a secure timestamp; a transient timestamp-service failure never enables an
unsigned or untimestamped fallback.
"""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time

DEFAULT_IDENTITY = "Developer ID Application: Zhaofeng Wang (43TXHV3TM3)"
TEAM_ID = "43TXHV3TM3"
APP_ID = "com.belloware.PiApp"
APP_ENTITLEMENTS = {"com.apple.security.app-sandbox": False}
RESTRICTED_ENTITLEMENTS = frozenset({
    "application-identifier", "com.apple.application-identifier",
    "com.apple.developer.team-identifier", "keychain-access-groups",
    "com.apple.security.application-groups",
})
SIGN_ATTEMPTS = 3
SIGN_RETRY_SECONDS = 2


def reject_restricted_entitlements(entitlements):
    if not isinstance(entitlements, dict):
        raise ValueError("Signing entitlements must be a property-list dictionary")
    restricted = RESTRICTED_ENTITLEMENTS.intersection(entitlements)
    if restricted:
        raise ValueError("Stale profile-based entitlements; rebuild the app: " + ", ".join(sorted(restricted)))


def read_entitlements(target, *, allow_unsigned=False):
    result = subprocess.run(["codesign", "--display", "--entitlements", "-", "--xml", str(target)], capture_output=True)
    if result.returncode:
        if allow_unsigned and b"code object is not signed at all" in result.stderr:
            return {}
        raise ValueError("Cannot inspect signing entitlements for " + str(target) + ": " +
                         result.stderr.decode("utf-8", errors="replace").strip())
    if not result.stdout.strip():
        return {}
    try:
        entitlements = plistlib.loads(result.stdout)
    except (ValueError, plistlib.InvalidFileException) as error:
        raise ValueError("Invalid signed entitlement data for " + str(target)) from error
    reject_restricted_entitlements(entitlements)
    return entitlements


def validate_profile_free(app, *, entitlements=None, allow_unsigned=True):
    app = Path(app)
    if not (app / "Contents/Info.plist").is_file():
        raise ValueError("Expected a complete macOS application bundle")
    profiles = [path for path in app.rglob("*")
                if path.name in {"embedded.provisionprofile", "embedded.mobileprovision"}]
    if profiles:
        raise ValueError("Stale embedded provisioning profile; rebuild the app without a profile")
    if entitlements is not None:
        source = plistlib.loads(Path(entitlements).read_bytes())
        reject_restricted_entitlements(source)
        if source != APP_ENTITLEMENTS:
            raise ValueError("Bello Agent release entitlements must contain only app-sandbox=false")
    signed = read_entitlements(app, allow_unsigned=allow_unsigned)
    reject_restricted_entitlements(signed)
    return signed


def sign(target, *, entitlements=None, runtime=True, identity=None):
    identity = identity or os.environ.get("SIGN_IDENTITY", DEFAULT_IDENTITY)
    if not identity.strip() or identity.strip() == "-":
        raise ValueError("A Developer ID signing identity is required; ad-hoc signing is not a release")
    command = ["codesign", "--force", "--sign", identity, "--timestamp"]
    if runtime:
        command.extend(["--options", "runtime"])
    if entitlements is not None:
        command.extend(["--entitlements", str(entitlements)])
    command.append(str(target))
    for attempt in range(1, SIGN_ATTEMPTS + 1):
        result = subprocess.run(command)
        if result.returncode == 0:
            return
        if attempt < SIGN_ATTEMPTS:
            print(f"Timestamped signing attempt {attempt} failed for {target}; retrying.", file=sys.stderr)
            time.sleep(SIGN_RETRY_SECONDS)
    raise RuntimeError(f"Failed to sign {target} with a secure timestamp after {SIGN_ATTEMPTS} attempts")


def validate_signature_metadata(metadata, *, identifier=None, runtime=True):
    lines = metadata.splitlines()
    if f"TeamIdentifier={TEAM_ID}" not in lines or not any(
            line.startswith("Authority=Developer ID Application:") and line.endswith(f"({TEAM_ID})")
            for line in lines):
        raise ValueError("Release must be signed by the BelloWare Developer ID Application certificate")
    if not any(line.startswith("Timestamp=") and line[len("Timestamp="):].strip() for line in lines):
        raise ValueError("Release signature has no secure timestamp")
    if runtime and not any(line.startswith("CodeDirectory ") and "(runtime)" in line for line in lines):
        raise ValueError("Application signature must enable the hardened runtime")
    if identifier is not None and f"Identifier={identifier}" not in lines:
        raise ValueError("Code signature has the wrong application identifier")


def validate_release_app(app):
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    if validate_profile_free(app, allow_unsigned=False) != APP_ENTITLEMENTS:
        raise ValueError("Signed Bello Agent must contain only the app-sandbox=false entitlement")
    result = subprocess.run(["codesign", "--display", "--verbose=4", str(app)], capture_output=True, check=True)
    validate_signature_metadata(result.stderr.decode("utf-8", errors="replace"), identifier=APP_ID)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    signing = commands.add_parser("sign")
    signing.add_argument("target", type=Path)
    signing.add_argument("--entitlements", type=Path)
    signing.add_argument("--no-runtime", action="store_true", help="For a DMG or framework, not executable code")
    preflight = commands.add_parser("preflight")
    preflight.add_argument("app", type=Path)
    preflight.add_argument("--entitlements", required=True, type=Path)
    validation = commands.add_parser("validate-app")
    validation.add_argument("app", type=Path)
    args = parser.parse_args()
    if args.command == "sign":
        sign(args.target, entitlements=args.entitlements, runtime=not args.no_runtime)
    elif args.command == "preflight":
        validate_profile_free(args.app, entitlements=args.entitlements)
    else:
        validate_release_app(args.app)


if __name__ == "__main__":
    main()
