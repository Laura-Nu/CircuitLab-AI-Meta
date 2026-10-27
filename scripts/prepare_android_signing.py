"""Create a private Android release identity once; never print or overwrite credentials."""
import os
from pathlib import Path
import secrets
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    private = ROOT / ".tools/android-signing"
    properties = ROOT / "apps/client/android/key.properties"
    keystore = private / "circuitlab-release.jks"
    if properties.exists() or keystore.exists():
        if not (properties.exists() and keystore.exists()):
            raise SystemExit("An existing signing identity needs review; nothing was overwritten.")
        print("Existing private signing identity preserved.")
        return
    keytool = shutil.which("keytool")
    if not keytool:
        raise SystemExit("Install a JDK and make keytool available before preparing Android signing.")
    private.mkdir(parents=True, exist_ok=True, mode=0o700)
    password = secrets.token_urlsafe(36)
    environment = {**os.environ, "CIRCUITLAB_SIGNING_PASSWORD": password}
    result = subprocess.run([
        keytool, "-genkeypair", "-keystore", str(keystore), "-storetype", "JKS",
        "-alias", "circuitlab", "-keyalg", "RSA", "-keysize", "3072", "-validity", "10000",
        "-storepass:env", "CIRCUITLAB_SIGNING_PASSWORD", "-keypass:env", "CIRCUITLAB_SIGNING_PASSWORD",
        "-dname", "CN=CircuitLab AI", "-noprompt",
    ], env=environment, capture_output=True)
    if result.returncode:
        raise SystemExit("Signing-key generation failed; private tool output was suppressed.")
    keystore.chmod(0o600)
    with properties.open("x", encoding="utf-8") as output:
        properties.chmod(0o600)
        output.write("storeFile=" + keystore.as_posix() + "\nstorePassword=" + password
                     + "\nkeyPassword=" + password + "\nkeyAlias=circuitlab\n")
    print("Private Android release identity prepared. Back up the keystore and key.properties securely for future updates.")


if __name__ == "__main__":
    main()
