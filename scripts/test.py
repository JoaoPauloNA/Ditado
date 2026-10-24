#!/usr/bin/env python3
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="ditado-tests-") as temporary:
    binary = Path(temporary) / "CoreTests"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                    str(root / "Sources/ShortcutConfiguration.swift"), str(root / "Sources/DictationCore.swift"), str(root / "Sources/PainelConnection.swift"),
                    str(root / "Tests/CoreTests.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
