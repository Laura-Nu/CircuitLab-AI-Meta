"""Public compatibility metadata; never expose arbitrary environment values."""
import os
import re

API_CONTRACT_VERSION = "2"
CAPABILITIES = ["functional_checks", "role_aware_reports", "browser_usb", "guided_completion", "lightweight_polling", "operation_assessment", "boolean_observations", "evidence_removal", "project_observations", "serial_captures"]


def deployment_metadata():
    revision = os.environ.get("CIRCUITLAB_BUILD_REVISION", "")
    return {
        "api_contract_version": API_CONTRACT_VERSION,
        "capabilities": CAPABILITIES,
        "build_revision": revision if re.fullmatch(r"[0-9a-f]{7,40}", revision) else "unknown",
    }
