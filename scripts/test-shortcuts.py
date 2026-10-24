#!/usr/bin/env python3
"""Check native conflict detection without sending keyboard events."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="ditado-shortcut-tests-") as temporary:
    directory = Path(temporary)
    holder = directory / "ShortcutHolder"
    tests = directory / "ShortcutTests"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(root / "Tests/ShortcutHolder.swift"),
                    "-framework", "Carbon", "-framework", "AppKit", "-o", str(holder)], check=True)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                    str(root / "Sources/ShortcutConfiguration.swift"), str(root / "Sources/ShortcutRegistration.swift"),
                    str(root / "Tests/ShortcutTests.swift"), "-framework", "Carbon", "-framework", "AppKit", "-o", str(tests)], check=True)
    for arguments in [[], ["--non-exclusive"]]:
        process = subprocess.Popen([str(holder), *arguments], stdout=subprocess.PIPE, text=True)
        try:
            if process.stdout.readline().strip() != "Shortcut holder ready":
                raise RuntimeError("Could not reserve the fixture shortcut")
            subprocess.run([str(tests), *arguments], check=True, timeout=30)
        finally:
            process.terminate()
            process.wait(timeout=5)
