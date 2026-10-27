"""Generate isolated VPS configuration without contacting or changing the server."""
import argparse
from pathlib import Path, PurePosixPath
import re
import secrets

ROOT = Path(__file__).resolve().parents[1]


def validated_target(domain, site_root, port):
    domain = domain.lower().strip()
    if len(domain) > 253 or not re.fullmatch(r"(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}", domain):
        raise ValueError("Use a plain DNS hostname, without scheme, path, wildcard or port")
    target = PurePosixPath(site_root)
    if site_root in {"/var/www", "/srv", "/etc", "/etc/nginx", "/home", "/root"}:
        raise ValueError("Use a dedicated project directory, not a shared server root")
    if not target.is_absolute() or not re.fullmatch(r"/[A-Za-z0-9_./-]+", site_root) or ".." in target.parts or len(target.parts) < 3:
        raise ValueError("Use a dedicated absolute Linux project path")
    if not 1024 <= port <= 65535:
        raise ValueError("Choose an API loopback port between 1024 and 65535")
    return domain, str(target), port


def render(template, domain, site_root, port):
    domain, site_root, port = validated_target(domain, site_root, port)
    for key, value in {"DOMAIN": domain, "ROOT": site_root, "API_PORT": str(port)}.items():
        template = template.replace("@@" + key + "@@", value)
    if "@@" in template:
        raise ValueError("Unresolved Nginx template token")
    return template


def prepare(output, domain, site_root="/var/www/circuitlab", port=8014):
    domain, site_root, port = validated_target(domain, site_root, port)
    output = Path(output)
    # Never replace an existing environment or rotate an initialized database password.
    names = ["runtime.env", "circuitlab.http.conf", "circuitlab.https.conf"]
    if any((output / name).exists() for name in names):
        raise FileExistsError("Generated configuration already exists; preserve it and use a new output directory")
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    password = secrets.token_urlsafe(36)
    env = {
        "APP_ENV": "production", "APP_ORIGIN": "https://" + domain, "SITE_ROOT": site_root,
        "CIRCUITLAB_PROJECT_NAME": "circuitlab", "CIRCUITLAB_IMAGE": "circuitlab-vps-backend:0.1.0",
        "API_BIND_PORT": str(port), "POSTGRES_USER": "circuitlab", "POSTGRES_PASSWORD": password,
        "POSTGRES_DB": "circuitlab", "DATABASE_URL": f"postgresql+psycopg://circuitlab:{password}@postgres:5432/circuitlab",
        "STORAGE_ROOT": "/data/evidence", "AI_MODE": "meta", "META_PROVIDER": "meta",
        "META_API_BASE_URL": "https://api.meta.ai/v1", "META_API_KEY": "", "META_REASONING_MODEL": "muse-spark-1.3",
        "META_REASONING_EFFORT": "low", "META_TIMEOUT_SECONDS": "60", "WORKER_LEASE_SECONDS": "120",
        "STORYBOARD_MODE": "disabled", "STORYBOARD_API_KEY": "", "RECOVERY_DELIVERY": "resend",
        "RESEND_API_KEY": "", "RESEND_FROM": "",
    }
    (output / "runtime.env").write_text("\n".join(key + "=" + value for key, value in env.items()) + "\n", encoding="utf-8")
    (output / "runtime.env").chmod(0o600)
    for kind in ("http", "https"):
        source = (ROOT / f"infra/nginx/circuitlab.{kind}.conf.template").read_text(encoding="utf-8")
        (output / f"circuitlab.{kind}.conf").write_text(render(source, domain, site_root, port), encoding="utf-8")
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--domain", required=True)
    parser.add_argument("--root", default="/var/www/circuitlab")
    parser.add_argument("--api-port", type=int, default=8014)
    parser.add_argument("--output", type=Path, default=ROOT / ".tools/vps")
    args = parser.parse_args()
    try:
        target = prepare(args.output, args.domain, args.root, args.api_port)
    except (ValueError, OSError) as exc:
        parser.exit(1, type(exc).__name__ + ": " + str(exc) + "\n")
    print(f"Prepared configuration in {target}. Credentials are not printed. No server services were changed.")


if __name__ == "__main__":
    main()
