#!/usr/bin/env python3
"""The Sparkle appcast of a release: sign the update archive, write appcast.xml, verify one.

  appcast.py build 0.3.1                 print the build number (CFBundleVersion) of a version
  appcast.py notes 0.3.1                 print that version's section of CHANGELOG.md
  appcast.py key                         check the private key against SUPublicEDKey in Info.plist
  appcast.py make --version 0.3.1 --archive AgentGram-0.3.1.zip --notes notes.md --out appcast.xml
  appcast.py verify --version 0.3.1 [--appcast FILE|URL] [--archive FILE]
                                         the appcast lists that version and its signature is good
                                         (default: the published feed; the archive is downloaded)

The private key is read from the environment, SPARKLE_ED_PRIVATE_KEY: base64 of the 32-byte
ed25519 seed, the format Sparkle's own generate_keys exports. It is never printed. `verify`
needs only the public key, which is in App/Info.plist.
"""
import argparse
import base64
import email.utils
import os
import plistlib
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey

ROOT = Path(__file__).resolve().parent.parent
REPO = "https://github.com/domechn/agentgram"
FEED = f"{REPO}/releases/latest/download/appcast.xml"
NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
MIN_SYSTEM = "15.0"   # the prebuilt TDLib is built against the macOS 15 SDK
ET.register_namespace("sparkle", NS)


def build_number(version: str) -> int:
    """0.3.1 -> 301. Sparkle compares CFBundleVersion, so it must grow with every release."""
    m = re.fullmatch(r"(\d+)\.(\d{1,2})\.(\d{1,2})", version)
    if not m:
        raise ValueError(f"version must be MAJOR.MINOR.PATCH with minor and patch below 100: {version!r}")
    major, minor, patch = map(int, m.groups())
    return major * 10000 + minor * 100 + patch


def notes_for(version: str, changelog: str) -> str:
    """The body under `## <version>` in CHANGELOG.md."""
    m = re.search(rf"(?ms)^## {re.escape(version)}[ \t]*\n(.*?)(?=^## |\Z)", changelog)
    if not m or not m[1].strip():
        raise ValueError(f"CHANGELOG.md has no notes for {version}")
    return m[1].strip()


def private_key(seed_b64: str) -> Ed25519PrivateKey:
    try:
        seed = base64.b64decode(seed_b64.strip(), validate=True)
    except ValueError:
        seed = b""
    if len(seed) != 32:
        raise ValueError("SPARKLE_ED_PRIVATE_KEY must be base64 of a 32-byte ed25519 seed")
    return Ed25519PrivateKey.from_private_bytes(seed)


def public_b64(key: Ed25519PrivateKey) -> str:
    raw = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return base64.b64encode(raw).decode()


def plist_public_key(path=ROOT / "App" / "Info.plist") -> str:
    return plistlib.loads(Path(path).read_bytes())["SUPublicEDKey"]


def sign(key: Ed25519PrivateKey, data: bytes) -> str:
    """What Sparkle's sign_update prints as sparkle:edSignature: ed25519 over the archive bytes."""
    return base64.b64encode(key.sign(data)).decode()


def signature_ok(public: str, data: bytes, signature: str) -> bool:
    try:
        Ed25519PublicKey.from_public_bytes(base64.b64decode(public)).verify(base64.b64decode(signature), data)
        return True
    except (InvalidSignature, ValueError):
        return False


def archive_url(version: str) -> str:
    return f"{REPO}/releases/download/v{version}/AgentGram-{version}.zip"


def make_appcast(version: str, length: int, signature: str, notes: str, date=None) -> str:
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "AgentGram"
    ET.SubElement(channel, "link").text = REPO
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"AgentGram {version}"
    ET.SubElement(item, "pubDate").text = email.utils.formatdate(date, usegmt=True)
    ET.SubElement(item, f"{{{NS}}}version").text = str(build_number(version))
    ET.SubElement(item, f"{{{NS}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{NS}}}minimumSystemVersion").text = MIN_SYSTEM
    # The release body is Markdown; Sparkle 2 shows it as text when told so.
    ET.SubElement(item, "description", {f"{{{NS}}}format": "markdown"}).text = notes
    ET.SubElement(item, "enclosure", {
        "url": archive_url(version), "length": str(length), "type": "application/octet-stream",
        f"{{{NS}}}edSignature": signature})
    ET.indent(rss)
    return '<?xml version="1.0" encoding="utf-8"?>\n' + ET.tostring(rss, encoding="unicode") + "\n"


def parse_appcast(xml: str) -> list:
    items = []
    for item in ET.fromstring(xml).iter("item"):
        enclosure = item.find("enclosure")
        items.append({
            "build": int(item.findtext(f"{{{NS}}}version")),
            "version": item.findtext(f"{{{NS}}}shortVersionString"),
            "min_system": item.findtext(f"{{{NS}}}minimumSystemVersion"),
            "notes": item.findtext("description") or "",
            "url": enclosure.get("url"), "length": int(enclosure.get("length")),
            "signature": enclosure.get(f"{{{NS}}}edSignature")})
    return items


def check(xml: str, version: str, public: str, archive=None, fetch=None) -> dict:
    """The appcast's newest item is `version`, and its archive matches the length and signature.
    Raises ValueError saying what is wrong."""
    items = parse_appcast(xml)
    if not items:
        raise ValueError("the appcast has no items")
    item = max(items, key=lambda i: i["build"])
    if item["version"] != version:
        raise ValueError(f"the appcast's newest version is {item['version']}, not {version}")
    if item["build"] != build_number(version):
        raise ValueError(f"build {item['build']} does not belong to {version}")
    if item["url"] != archive_url(version):
        raise ValueError(f"unexpected archive URL: {item['url']}")
    if item["min_system"] != MIN_SYSTEM:
        raise ValueError(f"minimumSystemVersion is {item['min_system']}, not {MIN_SYSTEM}")
    data = archive if archive is not None else fetch(item["url"])
    if len(data) != item["length"]:
        raise ValueError(f"the archive is {len(data)} bytes, the appcast says {item['length']}")
    if not signature_ok(public, data, item["signature"]):
        raise ValueError("the archive's ed25519 signature does not verify against SUPublicEDKey")
    return item


def download(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=300) as resp:
        return resp.read()


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("build", "notes"):
        sub.add_parser(name).add_argument("version")
    sub.add_parser("key")
    make = sub.add_parser("make")
    make.add_argument("--version", required=True)
    make.add_argument("--archive", required=True)
    make.add_argument("--notes", required=True)
    make.add_argument("--out", required=True)
    verify = sub.add_parser("verify")
    verify.add_argument("--version", required=True)
    verify.add_argument("--appcast", default=FEED)
    verify.add_argument("--archive")
    args = p.parse_args(argv)
    try:
        if args.cmd == "build":
            print(build_number(args.version))
        elif args.cmd == "notes":
            print(notes_for(args.version, (ROOT / "CHANGELOG.md").read_text()))
        elif args.cmd == "key":
            if public_b64(private_key(os.environ.get("SPARKLE_ED_PRIVATE_KEY", ""))) != plist_public_key():
                raise ValueError("SPARKLE_ED_PRIVATE_KEY is not the private half of SUPublicEDKey in App/Info.plist")
            print("the signing key matches SUPublicEDKey")
        elif args.cmd == "make":
            key = private_key(os.environ.get("SPARKLE_ED_PRIVATE_KEY", ""))
            data = Path(args.archive).read_bytes()
            xml = make_appcast(args.version, len(data), sign(key, data), Path(args.notes).read_text().strip())
            check(xml, args.version, plist_public_key(), archive=data)   # never publish one that fails
            Path(args.out).write_text(xml)
            print(f"{args.out}: {args.version} (build {build_number(args.version)}), {len(data)} bytes, signature verifies")
        else:
            xml = download(args.appcast).decode() if "://" in args.appcast else Path(args.appcast).read_text()
            archive = Path(args.archive).read_bytes() if args.archive else None
            item = check(xml, args.version, plist_public_key(), archive=archive, fetch=download)
            print(f"OK: {item['version']} (build {item['build']}), {item['length']} bytes at {item['url']}, "
                  "signature verifies against SUPublicEDKey")
    except (ValueError, OSError, KeyError, ET.ParseError) as e:
        sys.exit(f"error: {e}")


if __name__ == "__main__":
    main()
