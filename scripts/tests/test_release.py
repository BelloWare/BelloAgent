import importlib.util
import pathlib
import tempfile
import unittest
import xml.etree.ElementTree as ET
import sys
sys.path.insert(0, str(pathlib.Path(__file__).parents[1]))
from release_download import validate_prefix

spec = importlib.util.spec_from_file_location("release", pathlib.Path(__file__).parents[1] / "validate-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.archive = self.root / "BelloAgent-0.0.2.dmg"
        self.archive.write_bytes(b"synthetic archive")
        self.info = {"CFBundleName": "Bello Agent", "CFBundleDisplayName": "Bello Agent",
                     "CFBundleExecutable": "Bello Agent", "CFBundleIdentifier": "com.belloware.PiApp", "CFBundleShortVersionString": "0.0.2",
                     "CFBundleVersion": "2", "SUFeedURL": release.FEED, "SUPublicEDKey": release.PUBLIC_KEY}
        self.tree = ET.Element("rss")
        item = ET.SubElement(ET.SubElement(self.tree, "channel"), "item")
        ET.SubElement(item, release.SPARKLE + "version").text = "2"
        ET.SubElement(item, release.SPARKLE + "shortVersionString").text = "0.0.2"
        self.enclosure = ET.SubElement(item, "enclosure", {
            "url": "https://belloware.com/assets/BelloAgent-0.0.2.dmg", "length": "17",
            release.SPARKLE + "edSignature": "test-signature"})
        self.feed = self.root / "feed.xml"

    def validate(self, previous="1"):
        ET.ElementTree(self.tree).write(self.feed)
        return release.validate_metadata(self.feed, self.archive, self.info, previous)

    def test_accepts_monotonic_matching_release(self):
        self.assertEqual(self.validate(), "test-signature")

    def test_rejects_downgrade_and_republished_build(self):
        for previous in ["2", "3"]:
            with self.assertRaises(ValueError):
                self.validate(previous)

    def test_rejects_wrong_url(self):
        self.enclosure.set("url", "https://example.com/BelloAgent-0.0.2.dmg")
        with self.assertRaises(ValueError):
            self.validate()

    def test_external_installer_requires_an_explicit_matching_destination(self):
        self.enclosure.set("url", "https://downloads.example.com/pi/BelloAgent-0.0.2.dmg")
        with self.assertRaises(ValueError):
            self.validate()
        ET.ElementTree(self.tree).write(self.feed)
        self.assertEqual(release.validate_metadata(self.feed, self.archive, self.info, "1",
                         "https://downloads.example.com/pi/"), "test-signature")
        with self.assertRaises(ValueError):
            release.validate_metadata(self.feed, self.archive, self.info, "1", "https://different.example.com/pi/")

    def test_download_prefix_rejects_implicit_or_credential_bearing_destinations(self):
        for value in ["http://downloads.example/", "//downloads.example/", "https://user:secret@downloads.example/",
                      "https://downloads.example/?token=/", "https://downloads.example/#fragment/",
                      "https://downloads.example/path", "https://downloads.example/../", "https://down loads.example/"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_prefix(value)

    def test_rejects_changed_archive(self):
        self.archive.write_bytes(b"tampered")
        with self.assertRaises(ValueError):
            self.validate()

    def test_rejects_unsigned_feed(self):
        del self.enclosure.attrib[release.SPARKLE + "edSignature"]
        with self.assertRaises(ValueError):
            self.validate()

    def test_rejects_other_app(self):
        self.info["CFBundleIdentifier"] = "com.ainoob.BelloBox"
        with self.assertRaises(ValueError):
            self.validate()

    def test_rejects_old_display_name_even_when_identity_is_preserved(self):
        for field in ("CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"):
            with self.subTest(field=field):
                self.info[field] = "PiApp"
                with self.assertRaisesRegex(ValueError, "application name"):
                    self.validate()
                self.info[field] = "Bello Agent"

    def test_packaged_app_must_use_canonical_feed(self):
        self.info["SUFeedURL"] = "https://belloware.com/assets/pi_app.appcast.xml"
        with self.assertRaisesRegex(ValueError, "feed or signing key"):
            self.validate()


if __name__ == "__main__":
    unittest.main()
