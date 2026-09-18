"""Explicit HTTPS download destinations; the appcast always stays on BelloWare."""
from urllib.parse import urlsplit

DEFAULT_PREFIX = "https://belloware.com/assets/"


def validate_prefix(value):
    parsed = urlsplit(value)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username is not None
            or parsed.password is not None or parsed.query or parsed.fragment
            or not value.endswith("/") or any(c.isspace() for c in value)
            or any(part in (".", "..") for part in parsed.path.split("/"))):
        raise ValueError("Download prefix must be an explicit HTTPS directory without credentials, query or fragment")
    return value
