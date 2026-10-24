#!/usr/bin/env python3
"""Exercise Accessibility insertion only in a dedicated, background test window."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="ditado-paste-tests-") as temporary:
    directory = Path(temporary)
    fixture = directory / "PasteFixture"
    tests = directory / "PasteTests"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(root / "Tests/PasteFixture.swift"),
                    "-framework", "AppKit", "-o", str(fixture)], check=True)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                    str(root / "Sources/AutomaticPaste.swift"), str(root / "Tests/PasteTests.swift"),
                    "-framework", "AppKit", "-framework", "Carbon", "-o", str(tests)], check=True)
    process = subprocess.Popen([str(fixture)], stdout=subprocess.PIPE, text=True)
    try:
        ready = process.stdout.readline().strip()
        if not ready.startswith("Fixture ready:"):
            raise RuntimeError("Paste fixture did not start")
        subprocess.run([str(tests), str(process.pid)], check=True, timeout=30)
    finally:
        process.terminate()
        process.wait(timeout=5)
