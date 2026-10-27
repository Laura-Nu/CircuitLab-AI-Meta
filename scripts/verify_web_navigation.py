"""Compile the web navigation regression and run it in an isolated headless Chrome."""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from threading import Thread

ROOT = Path(__file__).resolve().parents[1]


class Handler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def main():
    dart = os.environ.get("DART_EXECUTABLE") or shutil.which("dart")
    if dart and Path(dart).suffix.lower() in {".bat", ".cmd"}:
        direct = Path(dart).parent / "cache/dart-sdk/bin/dart.exe"
        if direct.is_file():
            dart = str(direct)
    chrome = os.environ.get("CHROME_EXECUTABLE") or shutil.which("google-chrome") or shutil.which("chromium")
    if not chrome and os.name == "nt":
        candidate = Path(os.environ.get("PROGRAMFILES", "C:/Program Files")) / "Google/Chrome/Application/chrome.exe"
        chrome = str(candidate) if candidate.is_file() else None
    if not dart or not chrome:
        raise SystemExit("Dart and Chrome are required; optionally set DART_EXECUTABLE and CHROME_EXECUTABLE.")
    work = ROOT / ".tools/validation"
    work.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="navigation-", dir=work) as temporary:
        target = Path(temporary)
        compiled = subprocess.run([dart, "compile", "js", "-O1", "test/web/navigation_smoke.dart", "-o", str(target / "smoke.js")],
                                  cwd=ROOT / "apps/client", capture_output=True, text=True)
        if compiled.returncode:
            print(compiled.stdout + compiled.stderr)
            raise SystemExit("Navigation regression compilation failed.")
        (target / "index.html").write_text('<!doctype html><html><head><meta charset="utf-8"></head><body data-result="waiting"><script src="smoke.js"></script></body></html>', encoding="utf-8")
        server = ThreadingHTTPServer(("127.0.0.1", 0), partial(Handler, directory=str(target)))
        Thread(target=server.serve_forever, daemon=True).start()
        url = f"http://127.0.0.1:{server.server_address[1]}/index.html?from=app"
        command = [chrome, "--headless", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
                   "--user-data-dir=" + str(target / "profile"), "--virtual-time-budget=3000", "--dump-dom", url]
        if os.name != "nt" and hasattr(os, "geteuid") and os.geteuid() == 0:
            command.insert(1, "--no-sandbox")
        try:
            result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=45)
        finally:
            server.shutdown()
            server.server_close()
        if result.returncode or 'data-result="passed"' not in result.stdout:
            (work / "navigation-browser-output.html").write_text(result.stdout, encoding="utf-8")
            (work / "navigation-browser-errors.log").write_text(result.stderr, encoding="utf-8")
            raise SystemExit("Browser navigation failed; see private .tools/validation/navigation-browser-* output.")
        print("PASS: real Chrome navigation in the current tab, English/Spanish homepage URLs, non-web URL rejection.")


if __name__ == "__main__":
    main()
