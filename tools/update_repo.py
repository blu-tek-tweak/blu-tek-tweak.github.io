#!/usr/bin/env python3
"""Add a deb and refresh package/index sizes and hashes; use --check to verify."""
import argparse
import gzip
import hashlib
import io
from pathlib import Path
import shutil
import tarfile
from datetime import datetime, timezone
from email.utils import format_datetime

ROOT = Path(__file__).resolve().parents[1] / "repo"
HASHES = {"MD5Sum": "md5", "SHA1": "sha1", "SHA256": "sha256", "SHA512": "sha512"}


def deb_control(path):
    data = path.read_bytes()
    if not data.startswith(b"!<arch>\n"):
        raise ValueError(f"Invalid deb: {path}")
    offset = 8
    while offset < len(data):
        header = data[offset:offset + 60]
        size = int(header[48:58])
        member = data[offset + 60:offset + 60 + size]
        if header[:16].decode().strip().rstrip("/").startswith("control.tar"):
            with tarfile.open(fileobj=io.BytesIO(member), mode="r:*") as archive:
                control = next(item for item in archive if item.name.lstrip("./") == "control")
                return dict(line.split(": ", 1) for line in
                            archive.extractfile(control).read().decode().splitlines() if ": " in line)
        offset += 60 + size + size % 2
    raise ValueError(f"Missing control archive: {path}")


def stanzas():
    return [dict(line.split(": ", 1) for line in block.splitlines())
            for block in (ROOT / "Packages").read_text().strip().split("\n\n")]


def checksums(data):
    return {field: hashlib.new(algorithm, data).hexdigest() for field, algorithm in HASHES.items()}


def verify():
    for entry in stanzas():
        path = ROOT / entry["Filename"]
        data = path.read_bytes()
        assert entry["Size"] == str(len(data)), path
        assert all(entry[key] == value for key, value in checksums(data).items()), path
        control = deb_control(path)
        for key in ("Package", "Version", "Architecture", "Installed-Size"):
            assert entry[key] == control[key], (path, key)
    assert gzip.decompress((ROOT / "Packages.gz").read_bytes()) == (ROOT / "Packages").read_bytes()
    section = None
    for line in (ROOT / "Release").read_text().splitlines():
        if line.rstrip(":") in HASHES:
            section = line.rstrip(":")
        elif line.startswith(" "):
            digest, size, name = line.split()
            data = (ROOT / name).read_bytes()
            assert size == str(len(data)) and digest == checksums(data)[section], name
    print("Verified all package sizes, installed sizes, hashes, gzip contents and Release hashes.")


def update(package):
    control = deb_control(package)
    destination = ROOT / "pools" / "letterc" / package.name
    if destination.exists():
        raise ValueError(f"Package already exists: {destination}")
    shutil.copyfile(package, destination)
    entries = stanzas()
    entry = dict(control)
    entry["Filename"] = destination.relative_to(ROOT).as_posix()
    entries.append(entry)
    for entry in entries:
        data = (ROOT / entry["Filename"]).read_bytes()
        entry["Installed-Size"] = deb_control(ROOT / entry["Filename"])["Installed-Size"]
        entry["Size"] = str(len(data))
        entry.update(checksums(data))
    packages = ("\n\n".join("\n".join(f"{key}: {value}" for key, value in entry.items())
                                for entry in entries) + "\n").encode()
    (ROOT / "Packages").write_bytes(packages)
    (ROOT / "Packages.gz").write_bytes(gzip.compress(packages, mtime=0))
    release = (ROOT / "Release").read_text().split("MD5Sum:", 1)[0].splitlines()
    release = [f"Date: {format_datetime(datetime.now(timezone.utc))}" if line.startswith("Date:")
               else line for line in release]
    for field in HASHES:
        release.append(f"{field}:")
        for name in ("Packages", "Packages.gz"):
            data = (ROOT / name).read_bytes()
            release.append(f"  {checksums(data)[field]} {len(data)} {name}")
    (ROOT / "Release").write_text("\n".join(release) + "\n")
    verify()
    print(f"Added {control['Version']}: {destination.stat().st_size} bytes")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path, nargs="?")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.check:
        verify()
    elif args.package:
        update(args.package)
    else:
        parser.error("provide a deb or --check")
