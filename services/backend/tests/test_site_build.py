import importlib.util
from pathlib import Path
import shutil
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
    monkeypatch.setattr(site, "ROOT", fixture)
    output = site.build(tmp_path / "website")
    assert "CircuitLab AI" in (output / "index.html").read_text(encoding="utf-8")
    assert (output / "app/main.dart.js").read_text(encoding="utf-8") == "app fixture"
    assert (output / "en/index.html").exists()
    (flutter / "index.html").write_text('<base href="/">', encoding="utf-8")
    with pytest.raises(ValueError, match="--base-href /app/"):
        site.build(tmp_path / "wrong-base")
    with pytest.raises(ValueError, match="outside"):
        site.build(flutter / "app")
