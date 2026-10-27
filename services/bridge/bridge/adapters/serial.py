"""Real instrument adapter. A disconnect is an error, never a simulated fallback."""
import json
import math
import time
from .base import allowed, failed


class SerialAdapter:
    def __init__(self, config):
        if config.get("simulate", False) is not False:
            raise ValueError("SerialAdapter requires simulate=false")
        self.config = config

    def read(self, command):
        config = self.config
        calibration = config["calibration_id"]
        if not allowed(command, config):
            return failed(command, calibration, False, "precondition_failed")
        try:
            import serial
            deadline = time.monotonic() + command["deadline_ms"] / 1000
            # Never upload or execute user firmware. This speaks only the fixed instrument protocol.
            with serial.Serial(config["serial_port"], config.get("baudrate", 115200), timeout=0.2) as port:
                time.sleep(2)  # UNO resets when opening the port; configured deadline includes this.
                port.reset_input_buffer()
                port.write((json.dumps(command) + "\n").encode())
                while time.monotonic() < deadline:
                    line = port.readline()
                    if not line:
                        continue
                    result = json.loads(line)
                    if result.get("command_id") != command["command_id"]:
                        continue
                    if result.get("status") != "ok":
                        return failed(command, calibration, False, result.get("status", "out_of_range"))
                    value = float(result["value"])
                    if not math.isfinite(value) or not 0 <= value <= 5:
                        return failed(command, calibration, False, "out_of_range")
                    return {**failed(command, calibration, False), "status": "ok", "value": value,
                            "sample_count": result["sample_count"]}
        except (serial.SerialException, OSError):
            return failed(command, calibration, False, "disconnected")
        except (ValueError, KeyError):
            return failed(command, calibration, False, "out_of_range")
        return failed(command, calibration, False)


