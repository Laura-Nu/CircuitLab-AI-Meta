"""Package the public landing and the existing Flutter application into one static website."""
import argparse
import html
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


def render_landing(language, catalogs):
    template = (ROOT / "apps/landing/index.html").read_text(encoding="utf-8")
    texts = {key: html.escape(value, quote=True) for key, value in catalogs[language].items()}
    texts.update(locale=language, esPressed=str(language == "es").lower(), enPressed=str(language == "en").lower(),
                 messages=json.dumps(catalogs, ensure_ascii=False).replace("<", "\\u003c").replace(">", "\\u003e"))
    def substitute(match):
        key = match.group(1)
        if key not in texts:
            raise ValueError(f"Unknown landing placeholder: {key}")
        return texts[key]
    return re.sub(r"\{\{(\w+)\}\}", substitute, template)


def build(output, landing_only=False):
    catalogs = load_messages()
    flutter = ROOT / "apps/client/build/web"
    if output.resolve().is_relative_to(flutter.resolve()):
        raise ValueError("The website output must be outside the Flutter build directory")
    if not landing_only:
        index = flutter / "index.html"
        if not index.exists() or not re.search(r'<base\s+href=[\'"]/app/[\'"]', index.read_text(encoding="utf-8")):
            raise ValueError("First run flutter build web --base-href /app/ in apps/client")
    output.mkdir(parents=True, exist_ok=True)
    for language, destination in (("es", output / "index.html"), ("en", output / "en/index.html")):
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(render_landing(language, catalogs), encoding="utf-8")
    assets = output / "assets"
    shutil.copytree(ROOT / "apps/landing/assets", assets, dirs_exist_ok=True)
    for filename in ("Roboto-Regular.ttf", "Roboto-Bold.ttf", "LICENSE.txt"):
        shutil.copy2(ROOT / "apps/client/assets/fonts" / filename, assets / filename)
    shutil.copy2(ROOT / "apps/client/web/favicon.svg", output / "favicon.svg")
    if not landing_only:
        shutil.copytree(flutter, output / "app", dirs_exist_ok=True)
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/site")
    parser.add_argument("--landing-only", action="store_true", help="Build a preview without the Flutter application")
    args = parser.parse_args()
    try:
        print(build(args.output.resolve(), args.landing_only))
    except ValueError as exc:
        parser.exit(1, str(exc) + "\n")
