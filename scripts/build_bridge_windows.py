"""Build the Windows x64 desktop bridge without packaging any local credentials."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def build():
    if os.name != "nt" or platform.machine().lower() not in {"amd64", "x86_64"}:
        raise SystemExit("Build this release on Windows x64 with the bridge bundle dependency group.")
    sys.path.insert(0, str(ROOT / "services/bridge"))
    from bridge.desktop_config import VERSION
    work = ROOT / "build/bridge"
    assets = work / "assets"
    assets.mkdir(parents=True, exist_ok=True)
    png = (ROOT / "apps/client/web/icons/Icon-192.png").read_bytes()
    (assets / "bridge-icon.png").write_bytes(png)
    (assets / "bridge.ico").write_bytes(
        struct.pack("<HHH", 0, 1, 1) + struct.pack("<BBBBHHII", 192, 192, 0, 0, 1, 32, len(png), 22) + png
    )
    version = assets / "version.txt"
    version.write_text("""
VSVersionInfo(ffi=FixedFileInfo(filevers=(0,1,0,0), prodvers=(0,1,0,0), mask=0x3f,
flags=0x0, OS=0x40004, fileType=0x1, subtype=0x0, date=(0,0)),
kids=[StringFileInfo([StringTable('040904B0', [
StringStruct('CompanyName','CircuitLab AI'),
StringStruct('FileDescription','CircuitLab USB instrument bridge'),
StringStruct('FileVersion','0.1.0'),
StringStruct('ProductName','CircuitLab Bridge'),
StringStruct('ProductVersion','0.1.0'),
StringStruct('OriginalFilename','CircuitLab-Bridge.exe')])]),
VarFileInfo([VarStruct('Translation',[1033,1200])])])
""", encoding="utf-8")
    subprocess.run([
        sys.executable, "-m", "PyInstaller", "--noconfirm", "--clean", "--onefile", "--windowed", "--noupx",
        "--name", "CircuitLab-Bridge", "--distpath", str(work / "dist"),
        "--workpath", str(work / "work"), "--specpath", str(work),
        "--paths", str(ROOT / "services/bridge"), "--icon", str(assets / "bridge.ico"),
        "--version-file", str(version), "--add-data", str(assets / "bridge-icon.png") + ";.",
        str(ROOT / "services/bridge/desktop_entry.py"),
    ], cwd=ROOT, check=True)
    source = work / "dist/CircuitLab-Bridge.exe"
    if source.read_bytes()[:2] != b"MZ":
        raise SystemExit("The bundle is not a Windows executable")
    report = work / "self-test.json"
    subprocess.run([str(source), "--self-test-report", str(report)], check=True, timeout=60)
    result = json.loads(report.read_text(encoding="utf-8"))
    if result.get("status") != "ok" or result.get("version") != VERSION:
        raise SystemExit("The executable dependency check failed")
    release = ROOT / "releases/bridge"
    release.mkdir(parents=True, exist_ok=True)
    destination = release / "circuitlab-bridge-windows.exe"
    shutil.copy2(source, destination)
    checksum = hashlib.sha256(destination.read_bytes()).hexdigest()
    destination.with_suffix(".exe.sha256").write_text(checksum + "  " + destination.name + "\n", encoding="utf-8")
    (release / "manifest.json").write_text(json.dumps({
        "version": VERSION, "platform": "windows-x64", "filename": destination.name,
        "sha256": checksum, "size": destination.stat().st_size, "code_signed": False,
    }, indent=2) + "\n", encoding="utf-8")
    print("Windows desktop bridge built and dependency-checked:", destination)
    return destination


if __name__ == "__main__":
    build()
