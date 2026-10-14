#!/usr/bin/env python3
"""Refuse stale/unsafe PiApp .xctestrun products before a performance run."""
import os
from pathlib import Path
import plistlib
import pwd
import sys

TEST_ID = "com.belloware.PiAppTests.Host"


def test_targets(value):
    if isinstance(value, dict):
        if "TestHostPath" in value:
            yield value
        else:
            for item in value.values():
                yield from test_targets(item)
    elif isinstance(value, list):
        for item in value:
            yield from test_targets(item)


def validate(path):
    path = Path(path).resolve()
    targets = list(test_targets(plistlib.loads(path.read_bytes())))
    if not targets:
        raise ValueError("no hosted tests in the .xctestrun")
    real_home = Path(pwd.getpwuid(os.getuid()).pw_dir).resolve()
    for target in targets:
        host = Path(target["TestHostPath"].replace("__TESTROOT__", str(path.parent)))
        # macOS manifests may name the executable rather than the .app.
        app = next((part for part in (host, *host.parents) if part.suffix == ".app"), None)
        if app is None:
            raise ValueError("test host is not an app bundle")
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if info.get("CFBundleIdentifier") != TEST_ID:
            raise ValueError("test host must be " + TEST_ID)
        home = target.get("EnvironmentVariables", {}).get("CFFIXED_USER_HOME", "")
        home = home.replace("__TESTROOT__", str(path.parent))
        if not Path(home).is_absolute() or Path(home).resolve() == real_home:
            raise ValueError("test products require an isolated CFFIXED_USER_HOME")


if __name__ == "__main__":
    try:
        validate(sys.argv[1])
    except (IndexError, OSError, ValueError, KeyError, plistlib.InvalidFileException) as error:
        sys.exit("Refusing unsafe test products: " + str(error) + ". Rebuild with the checked-in PiApp scheme.")
