"""Check or deploy only CircuitLab's Compose project. Never edits Nginx or other services."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import socket
import subprocess
from urllib.parse import unquote, urlsplit

from prepare_vps import validated_target

ROOT = Path(__file__).resolve().parents[1]


class ConfigurationError(ValueError):
    """Fixed configuration messages; never include environment values."""


class DeploymentError(RuntimeError):
    """Fixed project-ownership and execution errors."""


def read_environment(path):
    result = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
            raise ConfigurationError("Invalid environment entry; values suppressed")
        if key in result:
            raise ConfigurationError("Duplicate environment key: " + key)
        result[key] = value.strip().strip("\"'")
    return result


def validate_config(env):
    required = ("APP_ORIGIN", "SITE_ROOT", "API_BIND_PORT", "CIRCUITLAB_PROJECT_NAME", "CIRCUITLAB_IMAGE",
                "POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB", "DATABASE_URL", "META_API_KEY", "META_REASONING_MODEL")
    missing = [key for key in required if not env.get(key)]
    if missing:
        raise ConfigurationError("Configure required variables: " + ", ".join(missing))
    origin = urlsplit(env["APP_ORIGIN"])
    if origin.scheme != "https" or origin.path not in {"", "/"} or origin.query or origin.fragment or origin.username or origin.port:
        raise ConfigurationError("APP_ORIGIN must be a domain-only HTTPS origin")
    if not env["API_BIND_PORT"].isdigit():
        raise ConfigurationError("API_BIND_PORT must be a numeric loopback port")
    domain, site_root, port = validated_target(origin.hostname or "", env["SITE_ROOT"], int(env["API_BIND_PORT"]))
    if domain == "example.com" or domain.endswith(".example.com"):
        raise ConfigurationError("Replace the example domain before deployment")
    if env.get("APP_ENV") != "production" or env.get("AI_MODE") != "meta" or env.get("STORYBOARD_MODE") != "disabled":
        raise ConfigurationError("Production requires APP_ENV=production, AI_MODE=meta and STORYBOARD_MODE=disabled")
    if env["POSTGRES_PASSWORD"] in {"CHANGE_ME", "TU_PASSWORD_DOCKER"} or len(env["POSTGRES_PASSWORD"]) < 20:
        raise ConfigurationError("Configure a strong database password")
    database = urlsplit(env["DATABASE_URL"])
    if (database.scheme != "postgresql+psycopg" or database.hostname != "postgres" or database.port != 5432
        or unquote(database.username or "") != env["POSTGRES_USER"]
        or unquote(database.password or "") != env["POSTGRES_PASSWORD"]
        or unquote(database.path.lstrip("/")) != env["POSTGRES_DB"]):
        raise ConfigurationError("DATABASE_URL must match the private Compose PostgreSQL service")
    if not re.fullmatch(r"circuitlab(?:-[a-z0-9-]+)?", env["CIRCUITLAB_PROJECT_NAME"]):
        raise ConfigurationError("Use a dedicated circuitlab Compose project name")
    if not re.fullmatch(r"circuitlab[-a-z0-9]*-backend:[a-zA-Z0-9_.-]+", env["CIRCUITLAB_IMAGE"]):
        raise ConfigurationError("Use a dedicated circuitlab backend image name")
    if env.get("RECOVERY_DELIVERY") == "resend" and not (env.get("RESEND_API_KEY") and env.get("RESEND_FROM")):
        raise ConfigurationError("Configure RESEND_API_KEY and RESEND_FROM, or explicitly disable recovery")
    if env.get("RECOVERY_DELIVERY") not in {"resend", "disabled"}:
        raise ConfigurationError("Production recovery supports resend or disabled")
    return domain, site_root, port


def run(args, **kwargs):
    # Never print subprocess output that may contain interpolated environment values.
    result = subprocess.run(args, capture_output=True, **kwargs)
    if result.returncode:
        raise DeploymentError("Command failed: " + args[0] + "; inspect this project's private logs on the VPS")
    return result


def existing_project(env):
    project = env["CIRCUITLAB_PROJECT_NAME"]
    result = run(["docker", "ps", "-a", "--filter", "label=com.docker.compose.project=" + project, "--format", "{{json .}}"], text=True)
    rows = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
    for row in rows:
        labels = json.loads(run(["docker", "inspect", "--format", "{{json .Config.Labels}}", row["ID"]], text=True).stdout)
        working = labels.get("com.docker.compose.project.working_dir", "")
        files = labels.get("com.docker.compose.project.config_files", "").split(",")
        if not working or not Path(working).resolve().is_relative_to(ROOT) or any(not Path(f).resolve().is_relative_to(ROOT) for f in files):
            raise DeploymentError("Compose project name belongs to a different directory; nothing was changed")
    if not rows:
        volumes = run(["docker", "volume", "ls", "--filter", "label=com.docker.compose.project=" + project,
                       "--format", "{{.Name}}"], text=True).stdout.strip()
        if volumes:
            raise DeploymentError("Existing volumes have no project containers; verify ownership before restoring them")
    images = run(["docker", "ps", "-a", "--filter", "ancestor=" + env["CIRCUITLAB_IMAGE"], "--format", "{{json .}}"], text=True)
    for line in images.stdout.splitlines():
        if line.strip() and ("com.docker.compose.project=" + project + ",") not in (json.loads(line).get("Labels", "") + ","):
            raise DeploymentError("The backend image is used by another project; choose a dedicated image name")
    return rows


def apply(env, compose):
    if os.name != "posix" or str(ROOT) != env["SITE_ROOT"]:
        raise DeploymentError("Apply must run on Linux from the configured dedicated project directory")
    if not (ROOT / "build/site/app/index.html").is_file():
        raise DeploymentError("Build the web app and landing before deployment")
    rows = existing_project(env)
    owned_api = any("com.docker.compose.service=api" in row.get("Labels", "")
                    and row.get("State") == "running"
                    and ("127.0.0.1:" + env["API_BIND_PORT"] + "->8000/tcp") in row.get("Ports", "")
                    for row in rows)
    if not owned_api:
        with socket.socket() as listener:
            try:
                listener.bind(("127.0.0.1", int(env["API_BIND_PORT"])))
            except OSError:
                raise DeploymentError("The API port is occupied; choose another port without stopping its owner") from None
    process_env = {**os.environ, **env}
    run(compose + ["config", "--quiet"], text=True, env=process_env)
    run(compose + ["build", "migrate"], text=True, env=process_env)
    run(compose + ["up", "-d", "--wait", "postgres"], text=True, env=process_env)
    backups = ROOT / ".tools/backups"
    backups.mkdir(parents=True, exist_ok=True, mode=0o700)
    backup = backups / ("postgres-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + ".dump")
    # A dedicated database/volume is never removed or reset. Back up before migrations.
    descriptor = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        result = subprocess.run(compose + ["exec", "-T", "postgres", "pg_dump", "-U", env["POSTGRES_USER"], "-d", env["POSTGRES_DB"], "-Fc"], stdout=output, stderr=subprocess.PIPE, env=process_env)
    if result.returncode or backup.stat().st_size == 0:
        raise DeploymentError("Database backup failed; migrations were not run")
    run(compose + ["run", "--rm", "--no-deps", "-T", "migrate"], text=True, env=process_env)
    run(compose + ["up", "-d", "--wait", "--no-deps", "api", "worker"], text=True, env=process_env)
    print("CircuitLab containers deployed. Nginx and other projects were not modified. Database backup: " + str(backup))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", type=Path, default=ROOT / ".env")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    try:
        env_file = args.env_file.resolve()
        env = read_environment(env_file)
        domain, site_root, port = validate_config(env)
        compose = ["docker", "compose", "--env-file", str(env_file), "-p", env["CIRCUITLAB_PROJECT_NAME"],
                   "-f", str(ROOT / "infra/compose.yaml"), "-f", str(ROOT / "infra/compose.production.yaml")]
        # Base Compose reads ROOT/.env as the container environment. Keep one authoritative file.
        if args.apply and env_file != ROOT / ".env":
            raise ConfigurationError("Install the reviewed environment as the project .env before applying")
        if args.check:
            print(f"Configuration valid for {domain}, {site_root}, loopback port {port}. No server changes made.")
        else:
            apply(env, compose)
    except (ValueError, OSError, RuntimeError) as error:
        # Variable names and fixed errors are safe; never echo values or raw Docker errors.
        message = str(error) if isinstance(error, (ConfigurationError, DeploymentError)) else type(error).__name__ + ": check the deployment configuration (values suppressed)"
        parser.exit(1, message + "\n")


if __name__ == "__main__":
    main()
