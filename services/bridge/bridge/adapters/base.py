"""Fixed acquisition protocol shared by explicitly selected adapters."""
import time


def failed(command, calibration, simulated, status="timeout"):
    return {"protocol_version": "1", "command_id": command["command_id"], "status": status,
        "point_id": command["point_id"], "value": None, "unit": "V", "sample_count": 0,
        "source": "simulated" if simulated else "instrumented", "calibration_id": calibration,
        "measured_at": time.time()}


def allowed(command, config):
    return (
        command.get("protocol_version") == "1" and command.get("action") == "read_voltage"
        and command.get("device_id") == config["device_id"]
        and command.get("point_id") in config["points"]
        and isinstance(command.get("sample_count"), int) and 1 <= command["sample_count"] <= 100
        and isinstance(command.get("deadline_ms"), int) and 100 <= command["deadline_ms"] <= 10000
    )
