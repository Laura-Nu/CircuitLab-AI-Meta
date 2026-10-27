import time
from bridge.main import Journal, acquire


def test_journal_replays_result_and_reserves_crashes(tmp_path):
    journal = Journal(tmp_path / "state.db")
    assert journal.reserve("c1") == (True, None)
    assert journal.reserve("c1") == (False, None)
    journal.finish("c1", {"status": "ok", "value": 1})
    assert journal.reserve("c1") == (False, {"status": "ok", "value": 1})
    journal.db.close()


def test_simulator_preserves_origin_and_validates_points():
    command = {"protocol_version": "1", "command_id": "test", "device_id": "d1", "action": "read_voltage",
        "point_id": "TP1", "sample_count": 20, "deadline_ms": 3000}
    config = {"device_id": "d1", "points": ["TP1"], "calibration_id": "cal-1", "simulate": True, "simulated_values": {"TP1": 2.5}}
    result = acquire(command, config)
    assert result["source"] == "simulated" and result["status"] == "ok"
    assert result["measured_at"] <= time.time()
    result = acquire({**command, "point_id": "TP9"}, config)
    assert result["status"] == "precondition_failed" and result["value"] is None


def test_real_adapter_never_falls_back_to_simulation(monkeypatch):
    import serial
    from bridge.adapters import SerialAdapter, SimulatedAdapter, adapter_for

    config = {"device_id": "d1", "points": ["TP1"], "calibration_id": "cal-1",
              "simulate": False, "serial_port": "MISSING", "simulated_values": {"TP1": 2.5}}
    command = {"protocol_version": "1", "command_id": "test", "device_id": "d1", "action": "read_voltage",
               "point_id": "TP1", "sample_count": 20, "deadline_ms": 3000}

    def disconnected(*args, **kwargs):
        raise serial.SerialException("Disconnected")

    monkeypatch.setattr(serial, "Serial", disconnected)
    assert isinstance(adapter_for(config), SerialAdapter)
    result = acquire(command, config)
    assert result["source"] == "instrumented" and result["status"] == "disconnected"
    assert result["value"] is None
    assert isinstance(adapter_for({**config, "simulate": True}), SimulatedAdapter)


def test_simulator_requires_explicit_bounded_fixture_values():
    from bridge.adapters import adapter_for
    import pytest

    command = {"protocol_version": "1", "command_id": "test", "device_id": "d1", "action": "read_voltage",
               "point_id": "TP1", "sample_count": 20, "deadline_ms": 3000}
    config = {"device_id": "d1", "points": ["TP1"], "calibration_id": "cal-1", "simulate": True}
    for value in [None, float("nan"), float("inf"), 6, -1]:
        result = acquire(command, {**config, "simulated_values": {"TP1": value}})
        assert result["status"] != "ok" and result["value"] is None and result["source"] == "simulated"
    with pytest.raises(ValueError):
        adapter_for({**config, "simulate": "false"})
