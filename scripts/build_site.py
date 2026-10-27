"""Package the public landing and the existing Flutter application into one static website."""
import argparse
import html
import hashlib
import os
import zipfile
import json
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load_messages():
    catalogs = {language: json.loads((ROOT / f"apps/landing/locales/{language}.json").read_text(encoding="utf-8"))
                for language in ("es", "en")}
    if catalogs["es"].keys() != catalogs["en"].keys():
        raise ValueError("Landing translation keys must match in English and Spanish")
    for key in catalogs["es"]:
        if not catalogs["es"][key] or not catalogs["en"][key]:
            raise ValueError(f"Empty landing translation: {key}")
    return catalogs


def render_landing(language, catalogs, apk_available=False):
    template = (ROOT / "apps/landing/index.html").read_text(encoding="utf-8")
    texts = {key: html.escape(value, quote=True) for key, value in catalogs[language].items()}
    label = "downloadAndroid" if apk_available else "downloadUnavailable"
    texts["downloadControl"] = (
        '<a class="button button-primary" data-apk-link href="/downloads/circuitlab-ai.apk" download="CircuitLab-AI.apk" data-i18n="downloadAndroid">' + texts[label] + '</a>'
        if apk_available else '<span class="download-pending" data-i18n="downloadUnavailable">' + texts[label] + '</span>'
    )
    texts["landingHref"] = "/en/" if language == "en" else "/"
    texts.update(locale=language, esPressed=str(language == "es").lower(), enPressed=str(language == "en").lower(),
                 messages=json.dumps(catalogs, ensure_ascii=False).replace("<", "\\u003c").replace(">", "\\u003e"))
    def substitute(match):
        key = match.group(1)
        if key not in texts:
            raise ValueError(f"Unknown landing placeholder: {key}")
        return texts[key]
    return re.sub(r"\{\{(\w+)\}\}", substitute, template)


def build(output, landing_only=False, apk=None):
    catalogs = load_messages()
    flutter = ROOT / "apps/client/build/web"
    if output.resolve().is_relative_to(flutter.resolve()):
        raise ValueError("The website output must be outside the Flutter build directory")
    if not landing_only:
        index = flutter / "index.html"
        if not index.exists() or not re.search(r'<base\s+href=[\'"]/app/[\'"]', index.read_text(encoding="utf-8")):
            raise ValueError("First run flutter build web --base-href /app/ in apps/client")
    output.mkdir(parents=True, exist_ok=True)
    # Prefer the versioned release so git pull also updates an existing VPS download.
    # A stale workstation build must not override the APK shipped by the repository.
    versioned_apk = ROOT / "releases/android/circuitlab-ai.apk"
    apk_source = Path(apk) if apk else (
        versioned_apk if versioned_apk.is_file()
        else ROOT / "apps/client/build/app/outputs/flutter-apk/app-release.apk"
    )
    download = output / "downloads/circuitlab-ai.apk"
    if apk_source.is_file():
        with zipfile.ZipFile(apk_source) as archive:
            if "AndroidManifest.xml" not in archive.namelist() or not any(name.startswith("lib/") for name in archive.namelist()):
                raise ValueError("Use a built Android release APK")
        download.parent.mkdir(parents=True, exist_ok=True)
        if apk_source.resolve() != download.resolve():
            shutil.copy2(apk_source, download)
    elif apk:
        raise ValueError("The specified APK does not exist")
    if download.is_file():
        checksum = hashlib.sha256(download.read_bytes()).hexdigest()
        (download.parent / "circuitlab-ai.apk.sha256").write_text(checksum + "  circuitlab-ai.apk\n", encoding="utf-8")
    for language, destination in (("es", output / "index.html"), ("en", output / "en/index.html")):
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(render_landing(language, catalogs, download.is_file()), encoding="utf-8")
    assets = output / "assets"
    shutil.copytree(ROOT / "apps/landing/assets", assets, dirs_exist_ok=True)
    for filename in ("Roboto-Regular.ttf", "Roboto-Bold.ttf", "LICENSE.txt"):
        shutil.copy2(ROOT / "apps/client/assets/fonts" / filename, assets / filename)
    shutil.copy2(ROOT / "apps/client/web/favicon.svg", output / "favicon.svg")
    if not landing_only:
        shutil.copytree(flutter, output / "app", dirs_exist_ok=True)
    if output.resolve() == (ROOT / "build/site").resolve():
        (ROOT / "build").chmod(0o755)
    # Only public output receives Nginx-readable permissions, even with a private umask.
    for directory, folders, files in os.walk(output, followlinks=False):
        if not Path(directory).is_symlink():
            Path(directory).chmod(0o755)
        for name in files:
            item = Path(directory) / name
            if not item.is_symlink():
                item.chmod(0o644)
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/site")
    parser.add_argument("--landing-only", action="store_true", help="Build a preview without the Flutter application")
    parser.add_argument("--apk", type=Path, help="Signed Android APK to publish with the landing")
    args = parser.parse_args()
    try:
        print(build(args.output.resolve(), args.landing_only, args.apk))
    except ValueError as exc:
        parser.exit(1, str(exc) + "\n")
