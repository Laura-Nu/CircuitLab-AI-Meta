import json
from pathlib import Path
import pytest
from app.main import app
from app.schemas import HardwareResult


def test_openapi_matches_export():
    contract = Path(__file__).resolve().parents[3] / "contracts/openapi.json"
    assert json.loads(contract.read_text(encoding="utf-8")) == app.openapi()


def test_error_result_cannot_include_reading():
    with pytest.raises(ValueError):
        HardwareResult(
            protocol_version="1",
            command_id="test",
            point_id="TP1",
            status="timeout",
            value=0,
            sample_count=0,
            source="instrumented",
            calibration_id="cal",
            measured_at=1,
        )
