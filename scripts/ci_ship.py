"""Send the checked public artifact to a restricted VPS SSH key. Never prints secrets."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile
from release_bundle import digest

ROOT = Path(__file__).resolve().parents[1]


def connection(env):
    required = ["CIRCUITLAB_SSH_HOST", "CIRCUITLAB_SSH_USER",
                "CIRCUITLAB_SSH_KEY", "CIRCUITLAB_SSH_KNOWN_HOSTS"]
    if any(not env.get(key, "").strip() for key in required):
        raise ValueError("Configure all CircuitLab SSH deployment secrets")
    host, user = env[required[0]], env[required[1]]
    if (not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.:-]*", host)
            or not re.fullmatch(r"[a-z_][a-z0-9_-]*", user)):
        raise ValueError("Invalid SSH destination")
    port = env.get("CIRCUITLAB_SSH_PORT", "22")
    if not port.isdigit() or not 1 <= int(port) <= 65535:
        raise ValueError("Invalid SSH port")
    return host, user, port


def ship(revision, bundle, env=None):
    env = os.environ if env is None else env
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Invalid approved revision")
    host, user, port = connection(env)
    expected = digest(bundle)
    sidecar = Path(str(bundle) + ".sha256")
    if not sidecar.is_file() or sidecar.read_text(encoding="ascii").strip() != expected:
        raise ValueError("Downloaded release checksum mismatch")
    with tempfile.TemporaryDirectory(prefix="circuitlab-ssh-") as directory:
        key, known = Path(directory) / "key", Path(directory) / "known_hosts"
        key.write_text(env["CIRCUITLAB_SSH_KEY"].strip() + "\n", encoding="utf-8")
        known.write_text(env["CIRCUITLAB_SSH_KNOWN_HOSTS"].strip() + "\n", encoding="utf-8")
        key.chmod(0o600)
        known.chmod(0o600)
        arguments = ["ssh", "-T", "-p", port, "-i", str(key),
                     "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
                     "-o", "StrictHostKeyChecking=yes", "-o", "HostKeyAlias=circuitlab-vps",
                     "-o", "UserKnownHostsFile=" + str(known),
                     "-o", "ConnectTimeout=20", user + "@" + host,
                     "circuitlab-deploy " + revision + " " + expected]
        with Path(bundle).open("rb") as source:
            result = subprocess.run(arguments, stdin=source, capture_output=True, timeout=1500)
        if result.returncode:
            raise RuntimeError("VPS deployment failed; inspect the restricted deployment and project logs privately")
    print("CircuitLab checked artifact delivered and deployment verified for " + revision)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--bundle", type=Path, default=ROOT / ".tools/ci/site.tar.gz")
    args = parser.parse_args()
    try:
        ship(args.revision, args.bundle)
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        message = str(error) if type(error) in {ValueError, RuntimeError} else "SSH deployment could not complete"
        parser.exit(1, message + "\n")


if __name__ == "__main__":
    main()
