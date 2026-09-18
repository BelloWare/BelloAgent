"""Exercise publication ordering using temporary sites and synthetic artifacts.

Platform signature/notarization commands and git are stubbed only in these
isolated fixtures. The real publisher and its metadata/site checks still run.
No fixture is suitable for distribution and no command contacts a remote.
"""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("stage_release_site", SCRIPTS / "stage-release-site.py")
staging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staging)


class ReleaseSiteFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="pi-release-site-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.site = self.root / "site"
        (self.site / "assets").mkdir(parents=True)
        (self.site / "index.html").write_text('<html><div class="products"><a href="existing.html">Existing</a></div></html>')
        (self.site / "sitemap.xml").write_text('<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>https://belloware.com/existing.html</loc></url></urlset>')
        (self.site / "assets/existing.bin").write_bytes(b"Existing unrelated product asset")
        self.release = self.root / "build/releases/0.1.2"
        contents = self.release / "Bello Agent.app/Contents"
        contents.mkdir(parents=True)
        self.info = {"CFBundleName": "Bello Agent", "CFBundleDisplayName": "Bello Agent",
                     "CFBundleExecutable": "Bello Agent", "CFBundleIdentifier": "com.belloware.PiApp", "CFBundleShortVersionString": "0.1.2",
                     "CFBundleVersion": "6", "SUFeedURL": staging.validation.FEED,
                     "SUPublicEDKey": staging.validation.PUBLIC_KEY}
        (contents / "Info.plist").write_bytes(plistlib.dumps(self.info))
        self.archive = self.release / "BelloAgent-0.1.2.dmg"
        self.archive.write_bytes(b"Synthetic fixture, not an installer")
        self.feed = self.release / "bello_agent.appcast.xml"
        self.write_feed()

    def write_feed(self, build="6", url="https://belloware.com/assets/BelloAgent-0.1.2.dmg"):
        root = ET.Element("rss")
        item = ET.SubElement(ET.SubElement(root, "channel"), "item")
        ET.SubElement(item, staging.validation.SPARKLE + "version").text = build
        ET.SubElement(item, staging.validation.SPARKLE + "shortVersionString").text = "0.1.2"
        ET.SubElement(item, "enclosure", {"url": url, "length": str(self.archive.stat().st_size),
                      staging.validation.SPARKLE + "edSignature": "synthetic-test-signature"})
        ET.ElementTree(root).write(self.feed)
        (self.release / "pi_app.appcast.xml").write_bytes(self.feed.read_bytes())

    def snapshot(self):
        return {str(path.relative_to(self.site)): ("symlink", os.readlink(path)) if path.is_symlink()
                else ("file", path.read_bytes()) for path in self.site.rglob("*") if path.is_symlink() or path.is_file()}


class StageReleaseSiteTests(ReleaseSiteFixture):
    def test_preflight_is_read_only_then_staging_preserves_other_products_and_is_idempotent(self):
        before = self.snapshot()
        staging.stage(self.release, self.site, check_only=True)
        self.assertEqual(self.snapshot(), before)
        staging.stage(self.release, self.site)
        after = self.snapshot()
        self.assertEqual(after["assets/existing.bin"], before["assets/existing.bin"])
        page = (self.site / "bello-agent.html").read_text()
        self.assertIn('href="https://belloware.com/assets/BelloAgent-0.1.2.dmg"', page)
        self.assertIn("Download Bello Agent 0.1.2", page)
        self.assertIn("SHA-256 fingerprints", page)
        self.assertIn("Activity in your menu bar", page)
        self.assertIn("Auto-router aliases", page)
        self.assertEqual((self.site / "assets/bello_agent_icon.png").read_bytes(),
                         (ROOT / "assets/branding/bello-agent-icon.png").read_bytes())
        self.assertEqual((self.site / "assets/pi_app.appcast.xml").read_bytes(), self.feed.read_bytes())
        self.assertEqual((self.site / "assets/bello_agent.appcast.xml").read_bytes(), self.feed.read_bytes())
        self.assertIn('content="0; url=/bello-agent.html"', (self.site / "pi-app.html").read_text())
        self.assertNotRegex(page, r"__[A-Z_]+__")
        self.assertEqual((self.site / "index.html").read_text().count('href="bello-agent.html"'), 1)
        self.assertIn('href="existing.html"', (self.site / "index.html").read_text())
        namespace = {"s": "http://www.sitemaps.org/schemas/sitemap/0.9"}
        urls = ET.parse(self.site / "sitemap.xml").findall("s:url/s:loc", namespace)
        self.assertEqual([item.text for item in urls], ["https://belloware.com/existing.html", "https://belloware.com/bello-agent.html"])
        staging.stage(self.release, self.site)
        self.assertEqual(self.snapshot(), after)

    def test_legacy_product_moves_to_canonical_discovery_without_losing_old_installers(self):
        (self.site / "index.html").write_text('<html><div class="products">' +
            '<a href="pi-app.html" class="product-card"><h3>Pi App</h3><p>Old product</p></a>' +
            '<a href="existing.html">Existing</a></div></html>')
        (self.site / "sitemap.xml").write_text('<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">' +
            '<url><loc>https://belloware.com/pi-app.html</loc></url>' +
            '<url><loc>https://belloware.com/existing.html</loc></url></urlset>')
        old_dmg = self.site / "assets/PiApp-0.0.2.dmg"
        old_dmg.write_bytes(b"Preserve old installer")
        staging.stage(self.release, self.site)
        index = (self.site / "index.html").read_text()
        self.assertNotIn('href="pi-app.html"', index)
        self.assertEqual(index.count('href="bello-agent.html"'), 1)
        self.assertIn('href="existing.html"', index)
        sitemap = (self.site / "sitemap.xml").read_text()
        self.assertNotIn("https://belloware.com/pi-app.html", sitemap)
        self.assertEqual(sitemap.count("https://belloware.com/bello-agent.html"), 1)
        self.assertIn("https://belloware.com/existing.html", sitemap)
        self.assertEqual(old_dmg.read_bytes(), b"Preserve old installer")

    def test_stale_compatibility_feed_fails_before_any_website_change(self):
        (self.release / "pi_app.appcast.xml").write_bytes(b"Old feed")
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, "legacy update feed"):
            staging.stage(self.release, self.site)
        self.assertEqual(self.snapshot(), before)

    def test_invalid_release_feed_does_not_write_any_website_file(self):
        for failure in ("mismatched-build", "credential-url", "changed-archive"):
            with self.subTest(failure=failure):
                self.write_feed()
                if failure == "mismatched-build": self.write_feed(build="7")
                elif failure == "credential-url": self.write_feed(url="https://secret@example.com/BelloAgent-0.1.2.dmg")
                else: self.archive.write_bytes(self.archive.read_bytes() + b"tampered")
                before = self.snapshot()
                with self.assertRaises(ValueError): staging.stage(self.release, self.site)
                self.assertEqual(self.snapshot(), before)

    def test_unknown_website_layout_and_duplicate_sitemap_fail_before_any_write(self):
        for failure in ("products-marker", "sitemap-namespace", "duplicate-entry"):
            with self.subTest(failure=failure):
                index = (self.site / "index.html").read_bytes()
                sitemap = (self.site / "sitemap.xml").read_bytes()
                if failure == "products-marker": (self.site / "index.html").write_text("<html>Unexpected website layout</html>")
                elif failure == "sitemap-namespace": (self.site / "sitemap.xml").write_text("<urlset/>")
                else:
                    (self.site / "sitemap.xml").write_text('<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">' +
                        '<url><loc>https://belloware.com/bello-agent.html</loc></url>' * 2 + '</urlset>')
                before = self.snapshot()
                with self.assertRaises(ValueError): staging.stage(self.release, self.site)
                self.assertEqual(self.snapshot(), before)
                (self.site / "index.html").write_bytes(index)
                (self.site / "sitemap.xml").write_bytes(sitemap)

    def test_destination_symlinks_cannot_overwrite_files_outside_the_site(self):
        outside = self.root / "outside.txt"
        outside.write_bytes(b"Preserve outside file")
        for name in ("bello-agent.html", "pi-app.html", "assets/bello_agent.appcast.xml", "assets/pi_app.appcast.xml",
                     "assets/BelloAgent-0.1.2.dmg", "assets/bello_agent_icon.png"):
            with self.subTest(name=name):
                link = self.site / name
                link.symlink_to(outside)
                before = self.snapshot()
                with self.assertRaises(ValueError): staging.stage(self.release, self.site)
                self.assertEqual(self.snapshot(), before)
                self.assertEqual(outside.read_bytes(), b"Preserve outside file")
                link.unlink()

    def test_native_installer_limit_applies_at_twenty_mib_before_writes(self):
        for length in (20 * 1048576, 26 * 1048576):
            with self.subTest(length=length):
                with self.archive.open("wb") as archive: archive.truncate(length)
                self.write_feed()
                before = self.snapshot()
                with self.assertRaisesRegex(ValueError, "20 MiB"): staging.stage(self.release, self.site)
                self.assertEqual(self.snapshot(), before)


class PublishReleaseOrderingTests(ReleaseSiteFixture):
    """Run the shell publisher; stub only irreversible/external commands."""

    def setUp(self):
        super().setUp()
        self.source = self.root / "source"
        for relative in ("scripts/publish-release.sh", "scripts/stage-release-site.py", "scripts/validate-release.py",
                         "scripts/release_download.py", "scripts/release_signing.py", "releases/bello-agent-page.html",
                         "assets/branding/bello-agent-icon.png"):
            destination = self.source / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, destination)
        self.commands = self.root / "commands"
        self.commands.mkdir()
        self.events = self.root / "events.jsonl"
        stub = self.commands / "fixture-command.py"
        stub.write_text("#!" + sys.executable + '\n' + '''import json, os, pathlib, plistlib, shutil, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["PI_FIXTURE_EVENTS"], "a") as output:
    output.write(json.dumps([name, args]) + "\\n")
if os.environ.get("PI_FIXTURE_FAIL") == name: sys.exit(1)
if name == "git":
    if args[:1] == ["-C"]: args = args[2:]
    if args[:1] == ["rev-parse"]:
        print("origin/master" if "--abbrev-ref" in args else "a" * 40)
elif name == "ditto":
    shutil.copyfile(args[0], args[1])
elif name == "codesign" and "--display" in args:
    if "--entitlements" in args:
        sys.stdout.buffer.write(plistlib.dumps({"com.apple.security.app-sandbox": False}))
    else:
        print("Identifier=com.belloware.PiApp\\nTeamIdentifier=43TXHV3TM3\\n"
              "Authority=Developer ID Application: Zhaofeng Wang (43TXHV3TM3)\\n"
              "Timestamp=Sep 15, 2026\\nCodeDirectory v=20500 flags=0x10000(runtime)", file=sys.stderr)
''')
        stub.chmod(0o755)
        for name in ("git", "swift", "codesign", "xcrun", "spctl", "ditto"):
            (self.commands / name).symlink_to(stub)
        self.env = {**os.environ, "PATH": str(self.commands) + os.pathsep + os.environ["PATH"],
                    "PI_BUILD_ROOT": str(self.root / "build"), "BELLOWARE_SITE_ROOT": str(self.site),
                    "PI_FIXTURE_EVENTS": str(self.events), "PI_DOWNLOAD_URL_PREFIX": staging.DEFAULT_PREFIX}
        self.env.pop("PI_FIXTURE_FAIL", None)

    def publish(self):
        return subprocess.run(["bash", str(self.source / "scripts/publish-release.sh"), "0.1.2"],
                              env=self.env, capture_output=True, text=True, timeout=20)

    def commands_run(self):
        return [json.loads(line) for line in self.events.read_text().splitlines()] if self.events.exists() else []

    def assert_no_publication(self):
        for name, args in self.commands_run():
            self.assertNotEqual(name, "ditto", "The installer must not be copied before preflight passes")
            if name == "git": self.assertFalse(any(arg in ("add", "commit", "push") for arg in args))

    def test_publisher_rejects_invalid_feed_site_and_oversized_archive_without_copy_or_commit(self):
        for failure in ("feed", "website", "oversized"):
            with self.subTest(failure=failure):
                self.events.unlink(missing_ok=True)
                self.write_feed()
                index = (self.site / "index.html").read_bytes()
                if failure == "feed": self.write_feed(build="99")
                elif failure == "website": (self.site / "index.html").write_text("Website layout changed")
                else:
                    with self.archive.open("wb") as archive: archive.truncate(20 * 1048576)
                    self.write_feed()
                before = self.snapshot()
                result = self.publish()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(self.snapshot(), before)
                self.assert_no_publication()
                (self.site / "index.html").write_bytes(index)

    def test_failed_signature_and_notarization_gates_do_not_mutate_website(self):
        for command in ("swift", "codesign", "xcrun", "spctl"):
            with self.subTest(command=command):
                self.events.unlink(missing_ok=True)
                self.env["PI_FIXTURE_FAIL"] = command
                before = self.snapshot()
                result = self.publish()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.snapshot(), before)
                self.assert_no_publication()

    def test_embedded_profile_is_rejected_before_publication(self):
        (self.release / "Bello Agent.app/Contents/embedded.provisionprofile").write_bytes(b"obsolete fixture")
        before = self.snapshot()
        result = self.publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Stale embedded provisioning profile", result.stderr)
        self.assertEqual(self.snapshot(), before)
        self.assert_no_publication()

    def test_validated_fixture_reaches_copy_then_commit_and_push_in_order(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.site / "assets/BelloAgent-0.1.2.dmg").read_bytes(), self.archive.read_bytes())
        self.assertEqual((self.site / "assets/bello_agent.appcast.xml").read_bytes(), self.feed.read_bytes())
        self.assertEqual((self.site / "assets/pi_app.appcast.xml").read_bytes(), self.feed.read_bytes())
        self.assertTrue((self.site / "bello-agent.html").is_file())
        operations = [args[2] if name == "git" and args[:1] == ["-C"] else name
                      for name, args in self.commands_run()]
        for prior, following in (("swift", "codesign"), ("codesign", "xcrun"), ("xcrun", "spctl"),
                                 ("spctl", "ditto"), ("ditto", "add"), ("add", "commit"), ("commit", "push")):
            self.assertLess(operations.index(prior), operations.index(following))

    def test_previous_build_is_checked_across_both_public_feeds(self):
        for feed_name in ("bello_agent.appcast.xml", "pi_app.appcast.xml"):
            with self.subTest(feed_name=feed_name):
                self.events.unlink(missing_ok=True)
                public_feed = self.site / "assets" / feed_name
                public_feed.write_bytes(self.feed.read_bytes())
                before = self.snapshot()
                result = self.publish()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Build number must increase", result.stderr)
                self.assertEqual(self.snapshot(), before)
                self.assert_no_publication()
                public_feed.unlink()


if __name__ == "__main__":
    unittest.main()
