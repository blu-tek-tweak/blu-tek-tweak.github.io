#!/usr/bin/env python3
"""Generate the binary PreferenceLoader entry plist for 26Wave.

Mirrors the working tweaks on this device. `isController` is the BOOLEAN true,
which tells the loader to instantiate the class named by NSPrincipalClass in
the bundle's Info.plist. `pl_alt_plist_name` explicitly tells the loader which
plist file in the bundle holds the specifiers (Root.plist).
"""
import plistlib
import sys

out = sys.argv[1] if len(sys.argv) > 1 else "26WavePrefs.plist"

data = {
    "entry": {
        "cell": "PSLinkCell",
        "bundle": "26WavePrefs",
        "label": "26Wave",
        "detail": "TW26PrefsRootListController",
        "isController": True,
        "icon": "icon.png",
    }
}

with open(out, "wb") as f:
    plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
print(f"wrote {out}")
