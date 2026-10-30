#!/usr/bin/env python3
"""Build a macOS Installer package without installing or modifying user data."""
from pathlib import Path
import argparse
import html
import plistlib
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
build = root / "build"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--skip-build", action="store_true", help="Package the existing built app")
args = parser.parse_args()
if not args.skip_build:
    subprocess.run(["python3", str(root / "scripts/build.py")], check=True)
app = build / "BlabberType.app"
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
name = "BlabberType"
version = info["CFBundleShortVersionString"]
output = build / f"{name}-{version}-instalador.pkg"

with tempfile.TemporaryDirectory(prefix="ditado-installer-") as temporary:
    work = Path(temporary)
    payload = work / "payload"
    (payload / "Applications").mkdir(parents=True)
    shutil.copytree(app, payload / "Applications" / app.name, symlinks=True)
    resources = work / "resources"
    resources.mkdir()
    (resources / "welcome.html").write_text(
        "<html><head><meta charset=\"utf-8\"></head><body><h1>Bem-vindo ao " + html.escape(name) + "</h1>"
        "<p>Este instalador adiciona o aplicativo à pasta Aplicativos do Mac.</p>"
        "<p>Após a instalação, abra o aplicativo e conceda as permissões necessárias "
        "para o ditado e a colagem automática.</p></body></html>", encoding="utf-8")
    (resources / "license.html").write_text(
        "<html><head><meta charset=\"utf-8\"></head><body><pre>" + html.escape((root / "LICENSE").read_text()) +
        "</pre></body></html>", encoding="utf-8")
    component = work / "component.pkg"
    subprocess.run(["pkgbuild", "--root", str(payload), "--identifier",
                    "app.ditado.desktop.installer", "--version", version,
                    "--install-location", "/", str(component)], check=True)
    distribution = work / "distribution.xml"
    distribution.write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>{html.escape(name)}</title>
  <welcome file="welcome.html"/>
  <license file="license.html"/>
  <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
  <domains enable_localSystem="true" enable_currentUserHome="false"/>
  <choices-outline><line choice="app"/></choices-outline>
  <choice id="app" visible="false"><pkg-ref id="app.ditado.desktop.installer"/></choice>
  <pkg-ref id="app.ditado.desktop.installer" version="{html.escape(version)}">component.pkg</pkg-ref>
</installer-gui-script>
''', encoding="utf-8")
    subprocess.run(["productbuild", "--distribution", str(distribution), "--resources",
                    str(resources), "--package-path", str(work), str(output)], check=True)
print(output)
