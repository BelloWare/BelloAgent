"""The public rename keeps old and new updater clients on the same archive.

Only downloads and platform signature commands are mocked. The production
verification script parses the real fixture XML and compares actual bytes.
"""
import contextlib
import io
from pathlib import Path
import runpy
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "verify-published.py"
sys.path.insert(0, str(SCRIPT.parent))
PREFIX = "https://belloware.com/assets/"
CANONICAL = "bello_agent.appcast.xml"
LEGACY = "pi_app.appcast.xml"
ARCHIVE = "BelloAgent-0.1.2.dmg"


class VerifyPublishedTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="bello-published-fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.release = self.root / "release"
        self.release.mkdir()
        self.downloads = self.root / "downloads"
        archive = b"Synthetic archive, not an installer"
        feed = ('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
                '<channel><item><enclosure url="' + PREFIX + ARCHIVE + '" '
                'sparkle:edSignature="synthetic-signature"/></item></channel></rss>').encode()
        self.public = {CANONICAL: feed, LEGACY: feed, ARCHIVE: archive}
        for name, content in self.public.items():
            (self.release / name).write_bytes(content)
        self.requests = []
        self.verifications = []

    def command(self, args, **kwargs):
        if args[0] == "/usr/bin/curl":
            self.requests.append(args[-1])
            destination = Path(args[args.index("--output") + 1])
            destination.write_bytes(self.public[args[-1].removeprefix(PREFIX)])
        elif args[0] == "swift":
            self.verifications.append(args)
        else:
            self.fail("Unexpected external command")

    def verify(self, *options):
        with patch.object(sys, "argv", [str(SCRIPT), str(self.release), str(self.downloads), *options]), \
             patch("subprocess.run", side_effect=self.command), contextlib.redirect_stdout(io.StringIO()):
            runpy.run_path(str(SCRIPT), run_name="__main__")

    def test_downloads_both_identical_feeds_then_compares_and_verifies_the_archive(self):
        self.verify()
        self.assertEqual(self.requests, [PREFIX + CANONICAL, PREFIX + LEGACY, PREFIX + ARCHIVE])
        self.assertEqual(len(self.verifications), 1)
        self.assertEqual(self.verifications[0][-1], "synthetic-signature")
        self.assertEqual(Path(self.verifications[0][2]).read_bytes(), self.public[ARCHIVE])

    def test_stale_legacy_feed_stops_before_archive_download_or_verification(self):
        self.public[LEGACY] = b"Previous release feed"
        with self.assertRaisesRegex(SystemExit, "same public update"):
            self.verify()
        self.assertEqual(self.requests, [PREFIX + CANONICAL, PREFIX + LEGACY])
        self.assertEqual(self.verifications, [])

    def test_archive_only_checks_new_archive_without_fetching_unpublished_feeds(self):
        self.verify("--archive-only")
        self.assertEqual(self.requests, [PREFIX + ARCHIVE])
        self.assertEqual(len(self.verifications), 1)

    def test_tampered_archive_stops_before_signature_verification(self):
        self.public[ARCHIVE] = b"Different public bytes"
        with self.assertRaisesRegex(SystemExit, "hash differs"):
            self.verify()
        self.assertEqual(self.verifications, [])


if __name__ == "__main__":
    unittest.main()
