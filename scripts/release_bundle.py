"""Build and validate the exact public website tested by CI. Contains no runtime environment."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import tarfile

ROOT = Path(__file__).resolve().parents[1]
SHA = re.compile(r"[0-9a-f]{40}")
ROOT_FILES = {"index.html", "favicon.svg", "release.json"}
ROOT_DIRECTORIES = {"app", "assets", "en", "downloads"}
MAX_BYTES = 512 * 1024 * 1024


def digest(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def public_name(name):
    path = PurePosixPath(name)
    if ("\\" in name or path.is_absolute() or not path.parts
            or any(part in {".", ".."} or part.startswith(".") for part in path.parts)):
        raise ValueError("Invalid public artifact path")
    if path.parts[0] not in ROOT_DIRECTORIES and path.as_posix() not in ROOT_FILES:
        raise ValueError("Artifact contains a non-public path")
    if path.suffix.lower() in {".key", ".pem", ".env", ".db", ".sqlite3", ".dump"}:
        raise ValueError("Artifact contains a private file type")
    return path.as_posix()


def package(revision, output, site=None):
    if not SHA.fullmatch(revision):
        raise ValueError("Invalid revision")
    site = site or ROOT / "build/site"
    if not (site / "app/index.html").is_file() or not (site / "index.html").is_file():
        raise ValueError("Build the complete website before packaging")
    apk = site / "downloads/circuitlab-ai.apk"
    checksum = site / "downloads/circuitlab-ai.apk.sha256"
    if not apk.is_file() or not checksum.is_file() or checksum.read_text(encoding="ascii").split()[0] != digest(apk):
        raise ValueError("The distributed APK checksum is missing or invalid")
    checksums = {}
    public_paths = []
    for path in sorted(site.rglob("*")):
        relative = path.relative_to(site).as_posix()
        if path.is_symlink():
            raise ValueError("Public artifacts must not contain symbolic links")
        # Flutter's local build stamp is bookkeeping, not a website resource.
        if relative == "app/.last_build_id" and path.is_file():
            continue
        name = public_name(relative)
        public_paths.append(path)
        if path.is_file() and name != "release.json":
            checksums[name] = digest(path)
    (site / "release.json").write_text(json.dumps({
        "format": 1, "revision": revision, "files": checksums,
    }, sort_keys=True) + "\n", encoding="utf-8")
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    if site / "release.json" not in public_paths:
        public_paths.append(site / "release.json")
    with tarfile.open(output, "w:gz") as archive:
        for path in public_paths:
            archive.add(path, arcname=path.relative_to(site).as_posix(), recursive=False)
    (output.parent / (output.name + ".sha256")).write_text(digest(output) + "\n", encoding="ascii")
    return output


def extract(bundle, revision, expected_digest, destination):
    if not SHA.fullmatch(revision) or not re.fullmatch(r"[0-9a-f]{64}", expected_digest):
        raise ValueError("Invalid release identity")
    if digest(bundle) != expected_digest:
        raise ValueError("Release archive checksum mismatch")
    destination = Path(destination)
    if destination.exists() or destination.is_symlink():
        raise ValueError("Release staging directory must be new")
    with tarfile.open(bundle, "r:gz") as archive:
        members = archive.getmembers()
        if len(members) > 10000 or sum(item.size for item in members) > MAX_BYTES:
            raise ValueError("Release exceeds the public artifact limit")
        names = set()
        for item in members:
            name = public_name(item.name.rstrip("/"))
            if name in names or not (item.isfile() or item.isdir()):
                raise ValueError("Duplicate paths or links in release archive")
            names.add(name)
        destination.mkdir(parents=True, mode=0o755)
        for item in members:
            target = destination / item.name
            if not target.resolve().is_relative_to(destination.resolve()):
                raise ValueError("Release path escapes its destination")
            if item.isdir():
                target.mkdir(parents=True, exist_ok=True, mode=0o755)
            else:
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
                with archive.extractfile(item) as source, target.open("xb") as output:
                    while block := source.read(1024 * 1024):
                        output.write(block)
                target.chmod(0o644)
    manifest = json.loads((destination / "release.json").read_text(encoding="utf-8"))
    if manifest.get("format") != 1 or manifest.get("revision") != revision:
        raise ValueError("Release manifest does not match the approved commit")
    actual = {p.relative_to(destination).as_posix() for p in destination.rglob("*")
              if p.is_file() and p.relative_to(destination).as_posix() != "release.json"}
    if actual != set(manifest.get("files", {})):
        raise ValueError("Release manifest file list mismatch")
    for name, expected in manifest["files"].items():
        public_name(name)
        if digest(destination / name) != expected:
            raise ValueError("Public file checksum mismatch")
    for directory in [destination, *(p for p in destination.rglob("*") if p.is_dir())]:
        directory.chmod(0o755)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--output", type=Path, default=ROOT / ".tools/ci/site.tar.gz")
    args = parser.parse_args()
    try:
        package(args.revision, args.output)
        print("Public release artifact created for " + args.revision)
    except (OSError, ValueError):
        parser.exit(1, "Could not package the public release; no credentials were printed\n")


if __name__ == "__main__":
    main()
