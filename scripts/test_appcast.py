"""Tests for appcast.py: `python3 -m unittest` in this folder. The key here is a throwaway."""
import base64
import re
import unittest
from pathlib import Path

import appcast as A

SEED = base64.b64encode(bytes(range(32))).decode()
ROOT = Path(__file__).resolve().parent.parent


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.key = A.private_key(SEED)
        self.public = A.public_b64(self.key)
        self.archive = b"PK\x03\x04 not really a zip"
        self.xml = A.make_appcast("0.3.1", len(self.archive), A.sign(self.key, self.archive),
                                  "- one <b> & two\n- 你好", date=0)

    def test_build_number_grows_with_the_version(self):
        versions = ["0.2.1", "0.3.0", "0.3.1", "0.10.0", "1.0.0"]
        builds = [A.build_number(v) for v in versions]
        self.assertEqual(builds, [201, 300, 301, 1000, 10000])
        self.assertEqual(builds, sorted(builds))
        self.assertGreater(builds[0], 4)   # 0.2.1 shipped as build 4
        for bad in ("0.3", "v0.3.0", "0.3.100", "0.3.0-beta", ""):
            with self.assertRaises(ValueError):
                A.build_number(bad)

    def test_known_ed25519_vector(self):
        # RFC 8032 test 1: the signature format is plain ed25519, which is what Sparkle verifies.
        seed = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
        key = A.private_key(base64.b64encode(seed).decode())
        self.assertEqual(base64.b64decode(A.public_b64(key)).hex(),
                         "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
        self.assertEqual(base64.b64decode(A.sign(key, b"")).hex(),
                         "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155"
                         "5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")

    def test_appcast_roundtrip(self):
        (item,) = A.parse_appcast(self.xml)
        self.assertEqual(item, {
            "build": 301, "version": "0.3.1", "min_system": "15.0", "notes": "- one <b> & two\n- 你好",
            "url": "https://github.com/domechn/agentgram/releases/download/v0.3.1/AgentGram-0.3.1.zip",
            "length": len(self.archive), "signature": A.sign(self.key, self.archive)})
        self.assertIn('xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"', self.xml)
        self.assertIn('sparkle:format="markdown"', self.xml)
        self.assertIn("Thu, 01 Jan 1970 00:00:00 GMT", self.xml)

    def test_check_accepts_the_real_thing_and_nothing_else(self):
        self.assertEqual(A.check(self.xml, "0.3.1", self.public, archive=self.archive)["build"], 301)
        fetched = []
        A.check(self.xml, "0.3.1", self.public, fetch=lambda url: fetched.append(url) or self.archive)
        self.assertEqual(fetched, [A.archive_url("0.3.1")])
        other = A.public_b64(A.private_key(base64.b64encode(bytes(32)).decode()))
        for xml, version, public, archive, error in (
                (self.xml, "0.3.0", self.public, self.archive, "newest version is 0.3.1"),
                (self.xml, "0.3.1", self.public, self.archive + b"x", "bytes"),
                (self.xml, "0.3.1", self.public, self.archive[:-1] + b"X", "does not verify"),
                (self.xml, "0.3.1", other, self.archive, "does not verify"),
                (self.xml.replace(">301<", ">300<"), "0.3.1", self.public, self.archive, "does not belong"),
                (self.xml.replace("v0.3.1/", "v0.3.0/"), "0.3.1", self.public, self.archive, "unexpected archive URL"),
                ("<rss><channel/></rss>", "0.3.1", self.public, self.archive, "no items")):
            with self.assertRaisesRegex(ValueError, error):
                A.check(xml, version, public, archive=archive)

    def test_bad_private_keys_are_refused_without_echoing_them(self):
        for bad in ("", "not base64!", base64.b64encode(b"short").decode()):
            with self.assertRaises(ValueError) as caught:
                A.private_key(bad)
            if bad:
                self.assertNotIn(bad, str(caught.exception))

    def test_notes_come_from_the_changelog(self):
        log = "# Changelog\n\n## 0.3.1\n\n- b\n\n## 0.3.0\n- a\n- a2\n"
        self.assertEqual(A.notes_for("0.3.1", log), "- b")
        self.assertEqual(A.notes_for("0.3.0", log), "- a\n- a2")
        with self.assertRaises(ValueError):
            A.notes_for("0.3", log)


class RepoTests(unittest.TestCase):
    """The checked-in pieces a release depends on agree with each other."""

    def setUp(self):
        self.version = re.search(r"MARKETING_VERSION: *(\S+)", (ROOT / "project.yml").read_text())[1]

    def test_the_committed_public_key_is_a_real_ed25519_key(self):
        self.assertEqual(len(base64.b64decode(A.plist_public_key())), 32)

    def test_the_current_version_has_release_notes_and_a_build_number(self):
        self.assertTrue(A.notes_for(self.version, (ROOT / "CHANGELOG.md").read_text()))
        self.assertGreater(A.build_number(self.version), 4)

    def test_the_bridge_has_the_apps_version(self):
        # The app shows its own version as the latest bridge.
        bridge = re.search(r'(?m)^VERSION = "([^"]+)"', (ROOT / "hermes-bridge" / "bridge.py").read_text())[1]
        self.assertEqual(bridge, self.version)


if __name__ == "__main__":
    unittest.main()
