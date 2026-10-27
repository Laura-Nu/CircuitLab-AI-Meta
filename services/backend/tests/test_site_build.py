import importlib.util
from pathlib import Path
import shutil
import hashlib
import zipfile
import pytest

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("build_site", ROOT / "scripts/build_site.py")
site = importlib.util.module_from_spec(spec)
spec.loader.exec_module(site)


def test_landing_is_available_in_both_languages_without_javascript():
    catalogs = site.load_messages()
    for language, title in [("es", "Entiende la falla."), ("en", "Understand the fault.")]:
        html = site.render_landing(language, catalogs)
        assert title in html
        assert f'<html lang="{language}">' in html
        assert f'/app/?lang={language}' in html
        assert "{{" not in html


def test_packaging_keeps_app_assets_under_their_base_path(tmp_path, monkeypatch):
    fixture = tmp_path / "source"
    for relative in ["apps/landing/index.html", "apps/landing/assets/landing.css", "apps/landing/assets/landing.js",
                     "apps/landing/locales/es.json", "apps/landing/locales/en.json", "apps/client/web/favicon.svg"]:
        destination = fixture / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / relative, destination)
    fonts = fixture / "apps/client/assets/fonts"
    fonts.mkdir(parents=True)
    for name in ["Roboto-Regular.ttf", "Roboto-Bold.ttf", "LICENSE.txt"]:
        (fonts / name).write_text("font fixture", encoding="utf-8")
    flutter = fixture / "apps/client/build/web"
    flutter.mkdir(parents=True)
    (flutter / "index.html").write_text('<base href="/app/">', encoding="utf-8")
    (flutter / "main.dart.js").write_text("app fixture", encoding="utf-8")
    # A fresh checkout and an existing VPS must publish the release from Git,
    # even if an older Android build still exists locally.
    release = fixture / "releases/android/circuitlab-ai.apk"
    release.parent.mkdir(parents=True)
    with zipfile.ZipFile(release, "w") as archive:
        archive.writestr("AndroidManifest.xml", "release manifest fixture")
        archive.writestr("lib/arm64-v8a/libapp.so", "versioned release fixture")
    stale = fixture / "apps/client/build/app/outputs/flutter-apk/app-release.apk"
    stale.parent.mkdir(parents=True)
    stale.write_bytes(b"stale local build must not be published")
    monkeypatch.setattr(site, "ROOT", fixture)
    output = site.build(tmp_path / "website")
    assert "CircuitLab AI" in (output / "index.html").read_text(encoding="utf-8")
    assert (output / "app/main.dart.js").read_text(encoding="utf-8") == "app fixture"
    assert (output / "en/index.html").exists()
    assert (output / "downloads/circuitlab-ai.apk").read_bytes() == release.read_bytes()
    assert "data-apk-link" in (output / "index.html").read_text(encoding="utf-8")
    checksum = hashlib.sha256(release.read_bytes()).hexdigest()
    assert (output / "downloads/circuitlab-ai.apk.sha256").read_text().startswith(checksum)

    (flutter / "index.html").write_text('<base href="/">', encoding="utf-8")
    with pytest.raises(ValueError, match="--base-href /app/"):
        site.build(tmp_path / "wrong-base")
    with pytest.raises(ValueError, match="outside"):
        site.build(flutter / "app")
