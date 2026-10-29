"""Synthetic serial frames validate the real adapter parser, not hardware acquisition."""
import json
import pytest
import serial
from bridge.main import acquire

COMMAND = {"protocol_version": "1", "command_id": "fixture", "device_id": "unit",
           "action": "read_digital", "point_id": "TP1", "sample_count": 20, "deadline_ms": 3000}
CONFIG = {"device_id": "unit", "points": ["TP1"], "calibration_id": "unit-only",
          "simulate": False, "serial_port": "FAKE"}


def fake_port(reply):
    class Port:
        def __init__(self, *a, **kw):
            pass
        def __enter__(self):
            return self
        def __exit__(self, *a):
            pass
        def reset_input_buffer(self):
            pass
        def write(self, raw):
            assert json.loads(raw)["action"] == "read_digital"
        def readline(self):
            return json.dumps({"command_id": "fixture", "point_id": "TP1", "status": "ok",
                               "sample_count": 20, "unit": "boolean", **reply}).encode()
    return Port


@pytest.mark.parametrize("value", [True, False])
def test_serial_and_simulated_adapters_preserve_boolean_with_distinct_origins(monkeypatch, value):
    monkeypatch.setattr(serial, "Serial", fake_port({"value": value}))
    monkeypatch.setattr("bridge.adapters.serial.time.sleep", lambda n: None)
    real = acquire(COMMAND, CONFIG)
    simulated = acquire(COMMAND, {**CONFIG, "simulate": True, "simulated_values": {"TP1": value}})
    assert real["value"] is value and simulated["value"] is value
    assert real["unit"] == simulated["unit"] == "boolean"
    assert real["source"] == "instrumented" and simulated["source"] == "simulated"


@pytest.mark.parametrize("reply", [{"value": 0}, {"value": "false"}, {"value": False, "unit": "V"},
                                   {"value": False, "point_id": "TP2"}, {"value": True, "sample_count": 19}])
def test_real_adapter_never_coerces_wrong_digital_frames(monkeypatch, reply):
    monkeypatch.setattr(serial, "Serial", fake_port(reply))
    monkeypatch.setattr("bridge.adapters.serial.time.sleep", lambda n: None)
    result = acquire(COMMAND, CONFIG)
    assert result["status"] != "ok" and result["value"] is None and result["source"] == "instrumented"
