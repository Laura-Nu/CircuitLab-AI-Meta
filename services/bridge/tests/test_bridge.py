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
    config = {"device_id": "d1", "points": ["TP1"], "calibration_id": "cal-1", "simulate": True}
    result = acquire(command, config)
    assert result["source"] == "simulated" and result["status"] == "ok"
    assert result["measured_at"] <= time.time()
    result = acquire({**command, "point_id": "TP9"}, config)
    assert result["status"] == "precondition_failed" and result["value"] is None
