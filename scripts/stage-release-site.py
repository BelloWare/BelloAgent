#!/usr/bin/env python3
"""Stage the product page/discovery links only for a validated feed/DMG pair.

The publisher performs signature/notarization checks before calling this helper.
No credentials, uploads, git operations or network calls happen here.
"""
import argparse
from datetime import date
import html
import io
import os
from pathlib import Path
import plistlib
import re
import tempfile
import xml.etree.ElementTree as ET

from release_download import DEFAULT_PREFIX
import importlib.util

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("validate_release", ROOT / "scripts/validate-release.py")
validation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validation)


def plan(release: Path, site: Path, prefix: str = DEFAULT_PREFIX):
    """Validate all inputs and return the complete set of intended file bytes."""
    if not site.is_dir() or not (site / "assets").is_dir() or (site / "assets").is_symlink():
        raise ValueError("Missing website directory or real assets directory")
    for name in ["index.html", "sitemap.xml", "bello-agent.html", "pi-app.html",
                 "assets/bello_agent_icon.png", "assets/bello_agent.appcast.xml", "assets/pi_app.appcast.xml"]:
        if (site / name).is_symlink():
            raise ValueError("Website release destinations must not be symbolic links")
    info = plistlib.loads((release / "Bello Agent.app/Contents/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("Invalid release version")
    archive = release / f"BelloAgent-{version}.dmg"
    if (site / "assets" / archive.name).is_symlink():
        raise ValueError("Website release destinations must not be symbolic links")
    validation.validate_metadata(release / "bello_agent.appcast.xml", archive, info, download_prefix=prefix)
    feed = (release / "bello_agent.appcast.xml").read_bytes()
    if (release / "pi_app.appcast.xml").read_bytes() != feed:
        raise ValueError("The legacy update feed must exactly match the canonical Bello Agent feed")
    if archive.stat().st_size >= 20 * 1048576:
        raise ValueError("The complete native installer must be below the 20 MiB release target")
    page = (ROOT / "releases/bello-agent-page.html").read_text()
    for name, value in {"VERSION": version, "DOWNLOAD_URL": prefix + archive.name,
                        "SIZE": f"{archive.stat().st_size / 1048576:.2f}"}.items():
        page = page.replace("__" + name + "__", html.escape(value, quote=True))
    if re.search(r"__[A-Z_]+__", page):
        raise ValueError("Unresolved page field")
    index = (site / "index.html").read_text()
    marker = '<div class="products">'
    if index.count(marker) != 1:
        raise ValueError("Website product list changed; review before publishing")
    card = '''
            <a href="bello-agent.html" class="product-card">
                <h3><img src="assets/bello_agent_icon.png" alt="Bello Agent icon" style="width: 32px; height: 32px; border-radius: 8px;"> Bello Agent</h3>
                <p>A native Mac AI workspace with coding tools, side conversations and menu bar token, cost and model insights. Connect your own LiteLLM gateway. Open source under the MIT License.</p>
                <span class="btn">Download Bello Agent &rarr;</span>
            </a>
'''
    # Rename the existing product card in place; future releases refresh the
    # same card without duplicating it or changing unrelated products.
    product = re.compile(r'\s*<a href="(?:pi-app|bello-agent)\.html" class="product-card">.*?</a>\s*', re.DOTALL)
    matches = list(product.finditer(index))
    if len(matches) > 1:
        raise ValueError("Duplicate Bello Agent product cards; review before publishing")
    expected_links = len(re.findall(r'href="(?:pi-app|bello-agent)\.html"', index))
    if expected_links != len(matches):
        raise ValueError("Website product card markup changed; review before publishing")
    if matches:
        index = product.sub(lambda _: card, index, count=1)
    else:
        index = index.replace(marker, marker + card, 1)
    namespace = "http://www.sitemaps.org/schemas/sitemap/0.9"
    ET.register_namespace("", namespace)
    tree = ET.parse(site / "sitemap.xml")
    if tree.getroot().tag != "{" + namespace + "}urlset":
        raise ValueError("Website sitemap namespace changed; review before publishing")
    location = "https://belloware.com/bello-agent.html"
    legacy = [item for item in tree.getroot() if item.findtext("{" + namespace + "}loc") == "https://belloware.com/pi-app.html"]
    if len(legacy) > 1:
        raise ValueError("Duplicate legacy Pi App sitemap entries; review before publishing")
    for item in legacy:
        tree.getroot().remove(item)
    entries = [item for item in tree.getroot() if item.findtext("{" + namespace + "}loc") == location]
    if len(entries) > 1:
        raise ValueError("Duplicate Bello Agent sitemap entries; review before publishing")
    entry = entries[0] if entries else None
    if entry is None:
        entry = ET.SubElement(tree.getroot(), "{" + namespace + "}url")
        ET.SubElement(entry, "{" + namespace + "}loc").text = location
        ET.SubElement(entry, "{" + namespace + "}changefreq").text = "monthly"
        ET.SubElement(entry, "{" + namespace + "}priority").text = "0.8"
    modified = entry.find("{" + namespace + "}lastmod")
    if modified is None: modified = ET.SubElement(entry, "{" + namespace + "}lastmod")
    modified.text = date.today().isoformat()
    # Validate every input before mutating the website working tree.
    icon = ROOT / "assets/branding/bello-agent-icon.png"
    if not icon.is_file(): raise ValueError("Missing Bello Agent icon")
    ET.indent(tree, space="    ")
    sitemap = io.BytesIO()
    tree.write(sitemap, encoding="UTF-8", xml_declaration=True)
    redirect = '''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Bello Agent | BelloWare</title><link rel="canonical" href="https://belloware.com/bello-agent.html">
<meta http-equiv="refresh" content="0; url=/bello-agent.html"></head>
<body><p>Pi App is now <a href="/bello-agent.html">Bello Agent</a>.</p></body></html>
'''
    return {site / "bello-agent.html": page.encode(), site / "pi-app.html": redirect.encode(),
            site / "index.html": index.encode(), site / "sitemap.xml": sitemap.getvalue(),
            site / "assets/bello_agent_icon.png": icon.read_bytes(),
            site / "assets/bello_agent.appcast.xml": feed, site / "assets/pi_app.appcast.xml": feed}


def stage(release: Path, site: Path, prefix: str = DEFAULT_PREFIX, check_only: bool = False):
    files = plan(release, site, prefix)
    if check_only:
        return
    for destination, content in files.items():
        # Per-file replacement prevents a truncated page if interrupted. The
        # publisher commits/pushes only after every intended file is staged.
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".bello-agent-", delete=False) as output:
                temporary = Path(output.name)
                output.write(content); output.flush(); os.fsync(output.fileno())
            temporary.chmod(0o644)
            temporary.replace(destination)
        finally:
            if temporary is not None and temporary.exists(): temporary.unlink()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("release", type=Path)
    parser.add_argument("site", type=Path)
    parser.add_argument("--download-url-prefix", default=DEFAULT_PREFIX)
    parser.add_argument("--check-only", action="store_true", help="Validate product/discovery staging without changing website files")
    args = parser.parse_args()
    stage(args.release, args.site, args.download_url_prefix, args.check_only)
