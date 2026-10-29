"""Send the checked public artifact to a restricted VPS SSH key. Never prints secrets."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile
from release_bundle import digest
from deploy_vps import BACKEND_STAGES

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


# Recognize diagnostic categories, but never forward SSH/provider/subprocess output.
# All user-visible messages below are local constants; remote text only selects a code.
REMOTE_FAILURES = {
    "Only a CircuitLab deployment command is allowed": (
        "remote_command_rejected", "The VPS rejected the deployment command; check its forced SSH command"),
    "This entry point is limited to Linux /var/www/circuitlab": (
        "remote_project_path", "The gateway must run from Linux /var/www/circuitlab"),
    "Another CircuitLab deployment is running": (
        "deployment_locked", "Another CircuitLab deployment holds the project lock; wait for it to finish"),
    "Project has tracked local changes; deployment refused": (
        "dirty_checkout", "The VPS has tracked local changes; inspect git status --short in /var/www/circuitlab"),
    "Project Git operation failed; inspect the VPS privately": (
        "remote_git_failed", "Git failed on the VPS; check that its deployment account can fetch origin/main non-interactively"),
    "A newer main commit exists; this outdated deployment was refused": (
        "outdated_revision", "A newer main commit exists; use the workflow run for the latest main commit"),
    "Deployment requires a fast-forward checkout": (
        "non_fast_forward", "The VPS checkout has diverged from main; inspect its history before updating"),
    "Incoming archive checksum mismatch": (
        "archive_checksum", "The received artifact checksum did not match; inspect the transfer"),
    "Release archive checksum mismatch": (
        "archive_checksum", "The received artifact checksum did not match; inspect the transfer"),
    "Incoming archive is too large": (
        "archive_too_large", "The public artifact exceeds the gateway transfer limit"),
    "Release manifest does not match the approved commit": (
        "artifact_revision", "The public artifact does not match the approved commit"),
    "Public file checksum mismatch": (
        "artifact_contents", "A public artifact file failed checksum validation"),
    "Release manifest file list mismatch": (
        "artifact_contents", "The public artifact file list failed validation"),
    "Configured root does not match the dedicated project directory": (
        "remote_configuration", "The VPS SITE_ROOT does not match /var/www/circuitlab; run scripts/deploy_vps.py --check"),
    "Public verification failed; previous website restored. Review API/worker privately": (
        "public_verification", "Public verification failed; the previous website was restored; inspect the CircuitLab API and worker"),
    "ConfigurationError": (
        "remote_configuration", "VPS configuration validation failed; run python3 scripts/deploy_vps.py --check on the VPS"),
    "DeploymentError": (
        "remote_backend_failed", "A VPS deployment operation failed; inspect only the CircuitLab Docker services and project logs"),
    "PermissionError": (
        "remote_permissions", "The VPS account cannot access a required project resource; check project ownership and permissions"),
    "FileNotFoundError": (
        "remote_missing_file", "A required VPS file or executable is missing; check the gateway, project .env, Git and Docker installation"),
}


def deployment_failure(result):
    """Return a safe fixed diagnostic even if remote stderr contains credentials."""
    stderr = result.stderr or b""
    if isinstance(stderr, bytes):
        stderr = stderr.decode("utf-8", errors="replace")
    lowered = stderr.lower()
    if result.returncode == 255:
        if any(item in lowered for item in (
            "host key verification failed", "remote host identification has changed",
            "no ed25519 host key is known", "no matching host key type",
        )):
            return ("ssh_host_key", "SSH could not verify the VPS identity; check CIRCUITLAB_SSH_KNOWN_HOSTS against the trusted VPS console")
        if any(item in lowered for item in (
            "invalid format", "error in libcrypto", "incorrect passphrase",
            "bad permissions", "load key", "unprotected private key file",
        )):
            return ("ssh_private_key", "SSH could not load the deployment key; CIRCUITLAB_SSH_KEY must contain the complete unencrypted private key")
        if "permission denied" in lowered or "too many authentication failures" in lowered:
            return ("ssh_authentication", "The VPS rejected SSH authentication; check SSH_USER and the matching public key in that account's authorized_keys")
        if any(item in lowered for item in (
            "connection refused", "connection timed out", "operation timed out",
            "could not resolve hostname", "network is unreachable", "no route to host",
        )):
            return ("ssh_connection", "SSH could not reach the VPS; check SSH_HOST, SSH_PORT and access from GitHub Actions")
        return ("ssh_transport", "The SSH connection failed; check the VPS SSH service and its authentication logs")
    for line in stderr.splitlines():
        prefix = "CircuitLab backend stage failed: "
        if line.startswith(prefix):
            stage = line[len(prefix):].strip()
            if stage in BACKEND_STAGES:
                return ("backend_" + stage, BACKEND_STAGES[stage])
    for line in stderr.splitlines():
        prefix = "CircuitLab deployment failed: "
        if line.startswith(prefix):
            reason = REMOTE_FAILURES.get(line[len(prefix):].strip())
            if reason:
                return reason
    if "circuitlab-deploy" in lowered and "command not found" in lowered:
        return ("ssh_forced_command", "The VPS tried to run circuitlab-deploy as a shell command; configure the restricted command in authorized_keys")
    if "deploy_gateway.py" in lowered and ("can't open file" in lowered or "no such file" in lowered):
        return ("remote_gateway_missing", "The VPS could not open deploy_gateway.py; install the gateway commit in /var/www/circuitlab first")
    return ("remote_failure", "The VPS command failed without a recognized safe diagnostic; inspect the project and SSH logs privately")


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
            code, message = deployment_failure(result)
            raise RuntimeError(f"Deployment failed [{code}] (SSH exit {result.returncode}): {message}")
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
