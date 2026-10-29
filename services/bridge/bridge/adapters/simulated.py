"""Explicit fixture values only; never opens a serial port or claims instrument readings."""
import math
from .base import allowed, failed


class SimulatedAdapter:
    def __init__(self, config):
        if config.get("simulate") is not True:
            raise ValueError("SimulatedAdapter requires simulate=true")
        self.config = config

    def read(self, command):
        config = self.config
        calibration = config["calibration_id"]
        if not allowed(command, config):
            return failed(command, calibration, True, "precondition_failed")
        value = config.get("simulated_values", {}).get(command["point_id"])
        if command["action"] == "read_digital":
            if type(value) is not bool:
                return failed(command, calibration, True, "precondition_failed")
            return {**failed(command, calibration, True), "status": "ok",
                    "sample_count": command["sample_count"], "value": value}
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            return failed(command, calibration, True, "precondition_failed")
        if not 0 <= value <= 5:
            return failed(command, calibration, True, "out_of_range")
        return {**failed(command, calibration, True), "status": "ok",
                "sample_count": command["sample_count"], "value": float(value)}
