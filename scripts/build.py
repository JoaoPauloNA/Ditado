#!/usr/bin/env python3
"""Build the native Ditado app without touching the Painel CLI installation."""
from pathlib import Path
import argparse
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--open", action="store_true", help="Open the built app in the background")
args = parser.parse_args()
bundle = ROOT / "build/Ditado.app"
contents = bundle / "Contents"
binary = contents / "MacOS/Ditado"
running = subprocess.check_output(["ps", "-axo", "comm="], text=True)
if str(binary) in [line.strip() for line in running.splitlines()]:
    raise SystemExit("Encerre o Ditado da pasta build antes de recompilar esse bundle.")
binary.parent.mkdir(parents=True, exist_ok=True)
(contents / "Resources").mkdir(exist_ok=True)
iconset = ROOT / "build/Ditado.iconset"
subprocess.run(["xcrun", "swift", str(ROOT / "scripts/create-icon.swift"), str(iconset)], check=True)
subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(contents / "Resources/AppIcon.icns")], check=True)
sources = sorted((ROOT / "Sources").glob("*.swift"))
subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                "-target", "arm64-apple-macosx14.0", *map(str, sources),
                "-framework", "SwiftUI", "-framework", "AppKit", "-framework", "Speech",
                "-framework", "AVFoundation", "-framework", "Carbon", "-framework", "Security",
                "-o", str(binary)], check=True)
with (contents / "Info.plist").open("wb") as output:
    plistlib.dump({
        "CFBundleExecutable": "Ditado", "CFBundleName": "Ditado",
        "CFBundleIdentifier": "app.ditado.desktop", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1.2", "CFBundleVersion": "3",
        "CFBundleIconFile": "AppIcon.icns",
        "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
        "NSMicrophoneUsageDescription": "Ditado usa o microfone somente quando você inicia uma gravação para transformar sua voz em texto.",
        "NSSpeechRecognitionUsageDescription": "Ditado usa o modelo de fala instalado no Mac para transcrever seus ditados localmente.",
        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
    }, output)
# A stable local identity keeps the Accessibility grant across rebuilds; ad-hoc signing
# changes the code identity on every build and macOS then drops the permission.
identity = "Ditado Local Signing" if subprocess.run(
    ["security", "find-identity", "-p", "codesigning"], capture_output=True, text=True
).stdout.count("Ditado Local Signing") else "-"
subprocess.run(["codesign", "--force", "--sign", identity, str(bundle)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
print(bundle)
if args.open:
    subprocess.run(["open", "-g", str(bundle)], check=True)
